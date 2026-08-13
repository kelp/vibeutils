//! chmod - Change file mode (permissions) utility
//!
//! Supports both numeric (octal) and symbolic mode specifications and recursive operations.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const builtin = @import("builtin");
const privilege_test = common.privilege_test;
const assert = std.debug.assert;

/// Command-line arguments for chmod
///
/// Field order is GNU chmod's own `longopts[]` order, because that is the
/// order an ambiguous abbreviation lists its candidates in (`chmod --v` ->
/// '--verbose' '--version'). Options vibeutils adds that GNU chmod has no
/// entry for sit after the GNU sequence.
const ChmodArgs = struct {
    changes: bool = false,
    recursive: bool = false,
    /// Do not treat '/' specially (default, no-op)
    no_preserve_root: bool = false,
    /// Refuse to operate recursively on '/'
    preserve_root: bool = false,
    reference: ?[]const u8 = null,
    silent: bool = false,
    verbose: bool = false,
    help: bool = false,
    version: bool = false,
    // Not in GNU chmod's longopts table.
    no_dereference: bool = false,
    /// Affect the referent of symlinks (default, no-op)
    dereference: bool = false,
    H: bool = false,
    L: bool = false,
    P: bool = false,
    /// Check ACL configuration (macOS, no-op stub)
    acl_check: bool = false,
    /// Read ACL info from stdin (macOS, no-op stub)
    acl_stdin: bool = false,
    /// Remove inherited bit from ACL entries (macOS, no-op stub)
    acl_remove_inherited: bool = false,
    /// Remove all inherited ACL entries (macOS, no-op stub)
    acl_remove_all_inherited: bool = false,
    /// Remove ACL from file (macOS, no-op stub)
    acl_remove: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .changes = .{ .short = 'c', .desc = "Like verbose but report only when a change is made" },
        .silent = .{ .short = 'f', .desc = "Suppress most error messages" },
        .verbose = .{ .short = 'v', .desc = "Output a diagnostic for every file processed" },
        .no_dereference = .{
            .short = 'h',
            .desc = "Do not follow symbolic links (change link itself)",
        },
        .recursive = .{ .short = 'R', .desc = "Change files and directories recursively" },
        .H = .{ .short = 'H', .desc = "Traverse symlinks given on the command line" },
        .L = .{ .short = 'L', .desc = "Traverse every symbolic link to a directory encountered" },
        .P = .{ .short = 'P', .desc = "Do not traverse any symbolic links (default)" },
        .reference = .{
            .desc = "Use reference file's mode instead of MODE",
            .value_name = "RFILE",
        },
        .acl_check = .{ .short = 'C', .desc = "Check ACL configuration (no-op)" },
        .acl_stdin = .{ .short = 'E', .desc = "Read ACL info from stdin (no-op)" },
        .acl_remove_inherited = .{
            .short = 'i',
            .desc = "Remove inherited bit from ACL entries (no-op)",
        },
        .acl_remove_all_inherited = .{
            .short = 'I',
            .desc = "Remove all inherited ACL entries (no-op)",
        },
        .acl_remove = .{ .short = 'N', .desc = "Remove ACL from file (no-op)" },
        .dereference = .{
            .short = 0,
            .desc = "Affect the referent of each symbolic link (default)",
        },
        .no_preserve_root = .{ .short = 0, .desc = "Do not treat '/' specially (default)" },
        .preserve_root = .{ .short = 0, .desc = "Fail to operate recursively on '/'" },
    };
};

/// Main entry point for chmod utility
pub fn runChmod(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Insert a "--" before a leading symbolic mode so argparse treats it as a
    // positional; effective_args is non-null only when a rewrite happened.
    const effective_args = try prepareArgs(allocator, args);
    defer if (effective_args) |ea| allocator.free(ea);
    const parse_args = effective_args orelse args;

    const parsed_args = common.argparse.ArgParser.parseOrExit(
        ChmodArgs,
        allocator,
        parse_args,
        "chmod",
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer allocator.free(parsed_args.positionals);

    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    const positionals = parsed_args.positionals;
    const using_reference = parsed_args.reference != null;
    if (!try checkOperandCount(allocator, positionals, using_reference, stderr_writer)) {
        return @intFromEnum(common.ExitCode.general_error);
    }

    // With --reference, all args are files; otherwise the first is the mode.
    const mode_str = if (using_reference) "" else positionals[0];
    const files = if (using_reference) positionals else positionals[1..];
    // checkOperandCount guarantees >= 1 file on both the --reference and the
    // mode+file paths, so no valid invocation reaches here with zero files.
    assert(files.len > 0);

    const options = buildOptions(parsed_args, parse_args);

    // --preserve-root: refuse to operate recursively on '/'.
    if (try preserveRootViolation(allocator, options, files, stderr_writer)) {
        return @intFromEnum(common.ExitCode.general_error);
    }

    chmodFiles(io, allocator, mode_str, files, stdout_writer, stderr_writer, options) catch |err| {
        reportChmodFilesError(allocator, stderr_writer, err, options);
        return @intFromEnum(common.ExitCode.general_error);
    };

    return @intFromEnum(common.ExitCode.success);
}

/// Report a top-level chmodFiles failure. FileOperationFailed, InvalidMode, and
/// InvalidOctalMode all mean a diagnostic was already printed upstream (either
/// the per-file failure, or resolveModeSpec's "invalid mode" message), so we
/// stay silent for those; any other error is an unexpected operation failure
/// worth surfacing once.
fn reportChmodFilesError(
    allocator: std.mem.Allocator,
    stderr_writer: anytype,
    err: anyerror,
    options: ChmodOptions,
) void {
    // Precompute membership so each branch below asserts a single condition
    // rather than a compound boolean (Tiger Style splits compound asserts).
    const already_reported = err == ChmodError.FileOperationFailed or
        err == ChmodError.InvalidMode or
        err == ChmodError.InvalidOctalMode;
    switch (err) {
        ChmodError.FileOperationFailed, ChmodError.InvalidMode, ChmodError.InvalidOctalMode => {
            // Positive space: this branch is only reached for the three
            // variants already reported upstream.
            assert(already_reported);
        },
        else => {
            // Negative space: this branch never fires for the three variants
            // already reported upstream.
            assert(!already_reported);
            if (!options.quiet) {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "chmod",
                    "operation failed: {s}",
                    .{common.posixErrorString(err)},
                );
            }
        },
    }
}

/// Rewrite args so a leading symbolic mode that starts with '-' (e.g. "-w",
/// "-rwx") is preceded by "--", forcing argparse to treat it and everything
/// after as positionals. Returns a freshly allocated slice the caller must
/// free, or null when no rewrite was needed (the original args suffice).
fn prepareArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) error{OutOfMemory}!?[]const []const u8 {
    for (args, 0..) |arg, idx| {
        // Stop scanning at "--": argparse already handles the explicit divider.
        if (std.mem.eql(u8, arg, "--")) break;
        // Only short-flag-shaped args ("-x", not "--long") can be ambiguous.
        if (arg.len <= 1 or arg[0] != '-' or arg[1] == '-') continue;
        if (!looksLikeSymbolicMode(arg)) continue;
        // Build args[0..idx] ++ ["--"] ++ args[idx..] so the mode survives.
        const new_args = try allocator.alloc([]const u8, args.len + 1);
        @memcpy(new_args[0..idx], args[0..idx]);
        new_args[idx] = "--";
        @memcpy(new_args[idx + 1 ..], args[idx..]);
        assert(new_args.len == args.len + 1);
        return new_args;
    }
    return null;
}

/// Validate that enough positional operands were supplied. Returns true when
/// the operand count is sufficient; otherwise it reports the error and returns
/// false so the caller can exit with the general_error status.
fn checkOperandCount(
    allocator: std.mem.Allocator,
    positionals: []const []const u8,
    using_reference: bool,
    stderr_writer: anytype,
) !bool {
    // With --reference we need at least one file; otherwise a mode plus a file.
    const minimum: usize = if (using_reference) 1 else 2;
    // minimum is exactly one of {1, 2} from the assignment above; bound it on
    // both sides so a future edit adding a third operand class fails loudly.
    assert(minimum >= 1);
    assert(minimum <= 2);
    if (positionals.len >= minimum) {
        return true;
    }
    const message = if (using_reference)
        "missing file operand\nTry 'chmod --help' for more information."
    else
        "missing operand\nTry 'chmod --help' for more information.";
    common.printErrorWithProgram(allocator, stderr_writer, "chmod", "{s}", .{message});
    assert(positionals.len < minimum);
    return false;
}

/// Build the ChmodOptions from parsed flags, resolving the mutually exclusive
/// -H / -L / -P symlink flags by last-flag-wins so passing both never panics.
fn buildOptions(parsed_args: ChmodArgs, parse_args: []const []const u8) ChmodOptions {
    assert(parse_args.len > 0);
    const symlink_policy = resolveSymlinkFlags(parsed_args, parse_args);
    // resolveSymlinkFlags returns exactly one of three SymlinkPolicy variants,
    // so precisely one of the mutually-exclusive option flags below is set:
    // never all-false, never multiple-true.
    assert(@intFromBool(symlink_policy == .follow_cmdline) +
        @intFromBool(symlink_policy == .follow_all) +
        @intFromBool(symlink_policy == .no_follow) == 1);
    return .{
        .changes_only = parsed_args.changes,
        .quiet = parsed_args.silent,
        .verbose = parsed_args.verbose,
        .no_dereference = parsed_args.no_dereference,
        .recursive = parsed_args.recursive,
        .traverse_cmdline_symlinks = symlink_policy == .follow_cmdline,
        .traverse_all_symlinks = symlink_policy == .follow_all,
        .no_traverse_symlinks = symlink_policy == .no_follow,
        .reference_file = parsed_args.reference,
        .preserve_root = parsed_args.preserve_root,
    };
}

/// GNU chmod treats -H / -L / -P as mutually exclusive with last-flag-wins.
/// The boolean parser cannot express ordering, so we re-scan the raw args to
/// find the final occurrence and return exactly one policy, never two at once.
fn resolveSymlinkFlags(
    parsed_args: ChmodArgs,
    parse_args: []const []const u8,
) common.walker.SymlinkPolicy {
    // No symlink flag set at all means the default -P (never follow).
    if (!parsed_args.H and !parsed_args.L and !parsed_args.P) {
        return .no_follow;
    }
    var policy: common.walker.SymlinkPolicy = .no_follow;
    for (parse_args) |arg| {
        // Stop at "--": everything after is a positional, not a flag.
        if (std.mem.eql(u8, arg, "--")) break;
        if (arg.len < 2 or arg[0] != '-' or arg[1] == '-') continue;
        // Short flags may be bundled (e.g. "-RL"); the last H/L/P wins.
        for (arg[1..]) |flag_char| {
            switch (flag_char) {
                'H' => policy = .follow_cmdline,
                'L' => policy = .follow_all,
                'P' => policy = .no_follow,
                else => {},
            }
        }
    }
    return policy;
}

/// Detect a --preserve-root violation (recursive chmod targeting '/'). Returns
/// true after reporting the error so the caller can exit with a failure code.
fn preserveRootViolation(
    allocator: std.mem.Allocator,
    options: ChmodOptions,
    files: []const []const u8,
    stderr_writer: anytype,
) !bool {
    assert(files.len > 0);
    if (!options.preserve_root or !options.recursive) {
        return false;
    }
    for (files) |file_path| {
        if (std.mem.eql(u8, file_path, "/")) {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "chmod",
                "it is dangerous to operate recursively on '/'\n" ++
                    "Use --no-preserve-root to override this failsafe.",
                .{},
            );
            return true;
        }
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runChmod);
}

/// Print usage information and examples
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
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
        \\  -h, --no-dereference   do not follow symbolic links (change link itself)
        \\      --dereference       affect the referent of each symbolic link (default)
        \\  -R, --recursive        change files and directories recursively
        \\      --reference=RFILE  use RFILE's mode instead of MODE values
        \\      --preserve-root    fail to operate recursively on '/'
        \\      --no-preserve-root do not treat '/' specially (default)
        \\      --help             display this help and exit
        \\      --version          output version information and exit
        \\
        \\The following options modify how a hierarchy is traversed when the -R
        \\option is also specified.  If more than one is specified, only the final
        \\one takes effect.
        \\
        \\  -H                     traverse symlinks given on the command line
        \\  -L                     traverse every symbolic link to a directory
        \\                         encountered
        \\  -P                     do not traverse any symbolic links (default)
        \\
        \\macOS ACL options (accepted but not implemented):
        \\  -C                     check ACL configuration
        \\  -E                     read ACL info from stdin
        \\  -i                     remove inherited bit from ACL entries
        \\  -I                     remove all inherited ACL entries
        \\  -N                     remove ACL from file
        \\
        \\Each MODE is of the form '[ugoa]*[-+=]([rwxXst]*|[ugo])'.
        \\
        \\Examples:
        \\  chmod 755 file.txt               Set file permissions to rwxr-xr-x
        \\  chmod u+x script.sh              Add execute permission for owner
        \\  chmod -R go-w /path/to/dir       Recursively remove write for group/other
        \\
    ;
    try common.help.printColorized(allocator, writer, help_text);
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
    no_dereference: bool = false,
    recursive: bool = false,
    traverse_cmdline_symlinks: bool = false,
    traverse_all_symlinks: bool = false,
    no_traverse_symlinks: bool = false,
    reference_file: ?[]const u8 = null,
    preserve_root: bool = false,
};

/// Unix file permissions with special bits
/// Shared Mode type from common.mode — identical struct with fromOctal/toOctal.
const Mode = common.mode.Mode;

/// Errors specific to chmod operations
const ChmodError = error{
    /// Invalid symbolic mode string
    InvalidMode,
    /// Invalid octal mode
    InvalidOctalMode,
    /// Reference file not found
    ReferenceFileNotFound,
    /// One or more file operations failed
    FileOperationFailed,
};

/// Specifies how to compute the new mode for a file
const ModeSpec = union(enum) {
    /// Apply a fixed octal mode
    octal: Mode,
    /// Apply a symbolic mode string relative to current permissions
    symbolic: []const u8,
    /// Apply the mode from a reference file
    reference: Mode,
};

/// Apply chmod operations to files
/// Handles both single files and recursive directory operations
fn chmodFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    mode_str: []const u8,
    files: []const []const u8,
    writer: anytype,
    stderr_writer: anytype,
    options: ChmodOptions,
) !void {
    assert(files.len > 0);

    const mode_spec = try resolveModeSpec(allocator, mode_str, stderr_writer, options);

    // Track if any file operations failed across all operands.
    var had_errors = false;
    for (files) |file_path| {
        const ok = if (options.recursive)
            chmodOneRecursive(io, allocator, file_path, mode_spec, writer, stderr_writer, options)
        else
            applyModeToPath(io, allocator, file_path, mode_spec, writer, stderr_writer, options);
        if (!ok) had_errors = true;
    }

    // A non-empty error tally signals overall failure to the caller.
    if (had_errors) {
        return ChmodError.FileOperationFailed;
    }
}

/// Resolve the single ModeSpec used for the whole run from either a reference
/// file's mode or the user-supplied mode string. Parsing once here keeps the
/// hot per-file loop free of redundant mode parsing.
fn resolveModeSpec(
    allocator: std.mem.Allocator,
    mode_str: []const u8,
    stderr_writer: anytype,
    options: ChmodOptions,
) !ModeSpec {
    if (options.reference_file) |ref_file| {
        const ref_stat = statByPath(ref_file) catch |err| {
            if (!options.quiet) {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "chmod",
                    "cannot access reference file '{s}': {s}",
                    .{ ref_file, common.posixErrorString(err) },
                );
            }
            return err;
        };
        return .{ .reference = Mode.fromOctal(@as(u32, @intCast(ref_stat.mode & 0o7777))) };
    }

    // A mode string is symbolic if it carries letters or operator characters.
    const is_symbolic = blk: {
        for (mode_str) |character| {
            if (std.ascii.isAlphabetic(character) or character == '+' or
                character == '-' or character == '=' or character == ',')
            {
                break :blk true;
            }
        }
        break :blk false;
    };
    if (is_symbolic) {
        return .{ .symbolic = mode_str };
    }

    // Warn if a numeric mode contains non-octal digits (8 or 9).
    if (hasNonOctalDigits(mode_str)) {
        common.printWarningWithProgram(
            allocator,
            stderr_writer,
            "chmod",
            "'{s}' contains non-octal digits; numeric modes use octal (0-7)",
            .{mode_str},
        );
    }
    const parsed = parseMode(mode_str) catch |err| switch (err) {
        ChmodError.InvalidMode, ChmodError.InvalidOctalMode => {
            if (!options.quiet) {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "chmod",
                    "invalid mode: '{s}'",
                    .{mode_str},
                );
            }
            return err;
        },
        else => return err,
    };
    return .{ .octal = parsed };
}

/// Apply the mode to a single command-line operand under -R. Resolves whether
/// the operand is a directory to descend (honoring -H / -L symlink following)
/// and dispatches to the bounded walker or a direct chmod. Returns true on
/// success, false if any error occurred, matching applyModeToPath's contract.
fn chmodOneRecursive(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    mode_spec: ModeSpec,
    writer: anytype,
    stderr_writer: anytype,
    options: ChmodOptions,
) bool {
    assert(options.recursive);

    const lstat_result = common.file.FileInfo.lstat(file_path) catch |err| {
        if (!options.quiet) {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "chmod",
                "cannot access '{s}': {s}",
                .{ file_path, common.posixErrorString(err) },
            );
        }
        return false;
    };

    const should_follow = lstat_result.kind == .sym_link and
        (options.traverse_cmdline_symlinks or options.traverse_all_symlinks);
    const effective_kind = if (should_follow) blk: {
        const target_stat = statByPath(file_path) catch |err| {
            if (!options.quiet) {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "chmod",
                    "cannot access '{s}': {s}",
                    .{ file_path, common.posixErrorString(err) },
                );
            }
            return false;
        };
        break :blk target_stat.kind;
    } else lstat_result.kind;

    if (effective_kind == .directory) {
        chmodWalk(
            io,
            allocator,
            file_path,
            mode_spec,
            writer,
            stderr_writer,
            options,
        ) catch return false;
        return true;
    }
    applyModeSpecToFile(file_path, mode_spec, writer, options) catch return false;
    return true;
}

/// Apply mode to a single path with proper error handling
/// Returns true on success, false on failure
fn applyModeToPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    mode_spec: ModeSpec,
    writer: anytype,
    stderr_writer: anytype,
    options: ChmodOptions,
) bool {
    // A symbolic spec must carry a non-empty mode string to re-parse per file.
    assert(mode_spec != .symbolic or mode_spec.symbolic.len > 0);
    _ = io;
    applyModeSpecToFile(file_path, mode_spec, writer, options) catch |err| {
        if (!options.quiet) {
            switch (err) {
                error.InvalidMode => {
                    if (mode_spec == .symbolic) {
                        common.printErrorWithProgram(
                            allocator,
                            stderr_writer,
                            "chmod",
                            "invalid mode: '{s}'",
                            .{mode_spec.symbolic},
                        );
                    } else {
                        common.printErrorWithProgram(
                            allocator,
                            stderr_writer,
                            "chmod",
                            "cannot access '{s}': {s}",
                            .{ file_path, common.posixErrorString(err) },
                        );
                    }
                },
                else => {
                    common.printErrorWithProgram(
                        allocator,
                        stderr_writer,
                        "chmod",
                        "cannot access '{s}': {s}",
                        .{ file_path, common.posixErrorString(err) },
                    );
                },
            }
        }
        return false;
    };
    return true;
}

/// Map chmod's symlink-traversal options onto the walker's symlink policy.
/// We honor -L (follow all), -H (follow command-line operands only), and the
/// default -P (never follow), so the bounded walker reproduces the recursion's
/// original behavior exactly.
fn symlinkPolicyFromOptions(options: ChmodOptions) common.walker.SymlinkPolicy {
    // The -L (follow_all) and -H (follow_cmdline) flags are mutually exclusive;
    // express "at most one set" arithmetically so the precondition carries no
    // compound boolean (Tiger Style splits compound asserts; the sum form is the
    // single-expression equivalent of !(a and b) without a top-level and/or).
    assert(@intFromBool(options.traverse_all_symlinks) +
        @intFromBool(options.traverse_cmdline_symlinks) <= 1);
    const policy: common.walker.SymlinkPolicy = if (options.traverse_all_symlinks)
        .follow_all
    else if (options.traverse_cmdline_symlinks)
        .follow_cmdline
    else
        .no_follow;
    // Postcondition: the chosen policy reflects the (mutually exclusive) inputs,
    // covering both follow branches so the full mapping is verified.
    assert((policy == .follow_all) == options.traverse_all_symlinks);
    assert((policy == .follow_cmdline) == options.traverse_cmdline_symlinks);
    return policy;
}

/// Apply chmod to a directory and all its contents using the bounded walker.
/// Post-order traversal preserves the original "open first, chmod the directory
/// last" invariant: a directory's children are emitted (and chmod'd) before the
/// directory itself, so removing a directory's search bit cannot lock the walk
/// out of its own contents. This replaces the former direct recursion, which
/// Tiger Style forbids, with an explicit bounded iteration.
fn chmodWalk(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    mode_spec: ModeSpec,
    writer: anytype,
    stderr_writer: anytype,
    options: ChmodOptions,
) !void {
    assert(dir_path.len > 0);
    assert(options.recursive);

    const config = common.walker.WalkConfig{
        .order = .post,
        .symlinks = symlinkPolicyFromOptions(options),
        .stay_on_filesystem = false, // chmod has no cross-device flag.
        // Ancestor-only cycles: a sibling symlink alias of an already-walked
        // directory is chmod'd again (GNU chmod -RL applies to both), while an
        // ancestor loop surfaces error.DirectoryCycle so the cycle-forming
        // symlink is serviced as a leaf without re-descending.
        .cycle_mode = .ancestors,
        // These caps make the driver loop below provably finite.
        .max_depth = 1024,
        .max_entries = 1 << 24,
    };
    // Walker.init requires a positive depth cap; assert the contract at the call
    // site so a future zero literal here fails loudly before init's own check.
    assert(config.max_depth > 0);
    // Likewise Walker.init requires a positive entry cap; mirror that precondition.
    assert(config.max_entries > 0);

    var walker = try common.walker.Walker.init(allocator, config);
    defer walker.deinit(io);
    try walker.addRoot(dir_path);

    // Track failures across the whole subtree, mirroring the recursion's
    // per-entry "catch -> had_errors" behavior so one bad entry does not abort
    // the rest of the walk.
    var had_errors = false;
    try walkAndApply(
        io,
        allocator,
        &walker,
        dir_path,
        mode_spec,
        writer,
        stderr_writer,
        options,
        &had_errors,
    );

    if (had_errors) {
        return ChmodError.FileOperationFailed;
    }
}

/// Drive the bounded walker to completion, applying the mode to every emitted
/// entry. Split out of chmodWalk to keep each function under the Tiger Style
/// 70-line cap. Records any per-entry failure in had_errors_out rather than
/// aborting, so one bad entry does not stop the rest of the walk.
fn walkAndApply(
    io: std.Io,
    allocator: std.mem.Allocator,
    walker: *common.walker.Walker,
    dir_path: []const u8,
    mode_spec: ModeSpec,
    writer: anytype,
    stderr_writer: anytype,
    options: ChmodOptions,
    had_errors_out: *bool,
) !void {
    assert(dir_path.len > 0);
    assert(options.recursive);

    // The walker bounds this loop via config.max_depth / config.max_entries: it
    // returns null when exhausted, or latches a terminal error once a cap is hit.
    while (true) { // tiger:allow:unbounded-loop next()->null exhausts; caps latch+break
        const maybe_entry = walker.next(io) catch |err| switch (err) {
            // Terminal cap errors latch (next() re-returns them forever), so we
            // report the reason and break, matching GNU's diagnostic-then-fail.
            error.DepthLimitExceeded, error.EntryLimitExceeded => {
                reportWalkLimit(allocator, stderr_writer, dir_path, err, options);
                had_errors_out.* = true;
                break;
            },
            // An ancestor symlink loop. GNU chmod -RL still chmods the
            // cycle-forming symlink itself as a leaf (rc stays 0) and does not
            // descend; apply the mode to the recorded cycle path and continue.
            error.DirectoryCycle => {
                if (!applyModeToPath(
                    io,
                    allocator,
                    walker.cyclePath(),
                    mode_spec,
                    writer,
                    stderr_writer,
                    options,
                )) had_errors_out.* = true;
                continue;
            },
            // Per-entry open/iterate errors leave the walker re-entrant; report
            // the failure and keep walking the remaining entries.
            else => {
                if (!options.quiet) {
                    common.printErrorWithProgram(
                        allocator,
                        stderr_writer,
                        "chmod",
                        "cannot read directory under '{s}': {s}",
                        .{ dir_path, common.posixErrorString(err) },
                    );
                }
                had_errors_out.* = true;
                continue;
            },
        };
        const entry = maybe_entry orelse break;
        switch (entry.kind) {
            // Under -P / -H the walker emits symlinks without descending them;
            // GNU chmod skips symlinks during recursive traversal, so do we.
            .sym_link => continue,
            else => {
                const result = applyModeToPath(
                    io,
                    allocator,
                    entry.path,
                    mode_spec,
                    writer,
                    stderr_writer,
                    options,
                );
                if (!result) had_errors_out.* = true;
            },
        }
    }
}

/// Report why the bounded walker stopped early when it hits a safety cap, so
/// the user sees a reason instead of a bare non-zero exit. The caps protect
/// against pathological trees and symlink cycles the cycle detector misses.
fn reportWalkLimit(
    allocator: std.mem.Allocator,
    stderr_writer: anytype,
    dir_path: []const u8,
    err: anyerror,
    options: ChmodOptions,
) void {
    assert(dir_path.len > 0);
    assert(err == error.DepthLimitExceeded or err == error.EntryLimitExceeded);
    if (options.quiet) return;
    // The format string must be comptime-known, so branch rather than select a
    // runtime string; each arm names the reason the walker refused to continue.
    if (err == error.DepthLimitExceeded) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "chmod",
            "directory too deep, recursion limit reached: '{s}'",
            .{dir_path},
        );
    } else {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "chmod",
            "too many entries, limit exceeded: '{s}'",
            .{dir_path},
        );
    }
}

/// Check whether an argument that starts with '-' is a symbolic chmod mode
/// rather than a flag. Returns true when the string after the leading '-'
/// contains a permission character (r, w, x, X, s, t) that is never a valid
/// chmod short flag, or a who specifier (u, g, o, a) followed by an operator.
/// Examples: "-w", "-r", "-rwx", "-a+x", "-go-w"
fn looksLikeSymbolicMode(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    // Never treat "--" as a mode
    if (arg.len >= 2 and arg[1] == '-') return false;
    const body = arg[1..];
    for (body) |c| {
        switch (c) {
            // Permission bits – never valid chmod flags
            'r', 'w', 'x', 'X', 's', 't' => return true,
            else => {},
        }
    }
    return false;
}

/// Check if a numeric-looking mode string contains non-octal digits (8 or 9).
/// Returns true only when the string starts with a digit and contains 8 or 9.
/// Symbolic modes (starting with letters or operators) always return false.
fn hasNonOctalDigits(mode_str: []const u8) bool {
    if (mode_str.len == 0) return false;
    // Only check strings that look numeric (start with a digit)
    if (!std.ascii.isDigit(mode_str[0])) return false;
    for (mode_str) |c| {
        if (c == '8' or c == '9') return true;
    }
    return false;
}

/// Stat a path, following symlinks. Returns mode and kind without needing io.
fn statByPath(path: []const u8) !struct { mode: std.posix.mode_t, kind: std.Io.File.Kind } {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.Io.Dir.max_path_bytes) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const c_path = buf[0..path.len :0];

    const raw_mode: u32, const kind: std.Io.File.Kind = blk: {
        if (builtin.os.tag == .linux) {
            // On Linux, std.c.fstatat is void; use statx syscall directly.
            const linux = std.os.linux;
            var sx: linux.Statx = undefined;
            const rc = linux.statx(
                std.Io.Dir.cwd().handle,
                c_path,
                0, // follow symlinks
                linux.STATX.BASIC_STATS,
                &sx,
            );
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .ACCES => return error.AccessDenied,
                .NOENT => return error.FileNotFound,
                .NOTDIR => return error.NotDir,
                .NAMETOOLONG => return error.NameTooLong,
                else => return error.Unexpected,
            }
            const mode: u32 = @intCast(sx.mode);
            const file_kind: std.Io.File.Kind = switch (mode & std.c.S.IFMT) {
                std.c.S.IFREG => .file,
                std.c.S.IFDIR => .directory,
                std.c.S.IFLNK => .sym_link,
                else => .unknown,
            };
            break :blk .{ mode & 0o7777, file_kind };
        } else {
            var stat_buf: std.c.Stat = undefined;
            const result = std.c.fstatat(std.Io.Dir.cwd().handle, c_path, &stat_buf, 0);
            if (result != 0) {
                const errno = std.posix.errno(result);
                return switch (errno) {
                    .SUCCESS => unreachable,
                    .ACCES => error.AccessDenied,
                    .BADF => error.FileNotFound,
                    .NOTDIR => error.NotDir,
                    .NAMETOOLONG => error.NameTooLong,
                    .NOENT => error.FileNotFound,
                    else => error.Unexpected,
                };
            }
            const mode: u32 = @intCast(stat_buf.mode);
            const S = std.posix.S;
            const file_kind: std.Io.File.Kind = blk2: {
                if (S.ISREG(stat_buf.mode)) break :blk2 .file;
                if (S.ISDIR(stat_buf.mode)) break :blk2 .directory;
                if (S.ISLNK(stat_buf.mode)) break :blk2 .sym_link;
                break :blk2 .unknown;
            };
            break :blk .{ mode & 0o7777, file_kind };
        }
    };

    // Both blk arms mask with 0o7777, so statByPath yields only permission and
    // special bits (setuid/setgid/sticky), never file-type bits.
    assert(raw_mode <= 0o7777);
    return .{ .mode = @intCast(raw_mode), .kind = kind };
}

/// Read and restore the process umask (POSIX has no non-destructive getter).
fn getUmask() u32 {
    const m = std.c.umask(0);
    _ = std.c.umask(m);
    return @intCast(m);
}

fn parseMode(mode_str: []const u8) !Mode {
    if (mode_str.len == 0) return ChmodError.InvalidMode;

    // Try octal first.
    if (common.mode.parseOctal(mode_str)) |octal| {
        // parseOctal rejects any value above 0o7777, so the success capture is
        // bounded to the permission/special-bit range fed into Mode.fromOctal.
        assert(octal <= 0o7777);
        return Mode.fromOctal(octal);
    } else |_| {}

    // Reject purely numeric strings that aren't valid octal.
    var all_numeric = true;
    for (mode_str) |c| {
        if (!std.ascii.isDigit(c)) {
            all_numeric = false;
            break;
        }
    }
    if (all_numeric) return ChmodError.InvalidOctalMode;

    // Symbolic mode: validate by parsing from base 0 (actual application
    // happens per-file in applyModeSpecToFile with the file's current mode).
    _ = common.mode.parseSymbolic(mode_str, 0, .{}) catch {
        return ChmodError.InvalidMode;
    };
    return Mode.fromOctal(0); // placeholder; symbolic modes are re-parsed per-file
}

// Local symbolic mode parsing functions removed. All symbolic mode logic now
// delegates to common.mode.parseSymbolic, which handles who-specifiers,
// operators (+/-/=), permission bits (rwx/X/s/t), permission copying (g=u),
// and POSIX umask masking for implicit-who clauses.

/// Convert error to user-friendly message
/// Apply a mode specification to a single file
/// Reports changes if verbose or changes_only flags are set
/// When no_dereference is set, operates on symlinks themselves via fchmodat
/// Stat a path for chmod, honoring the no_dereference flag: lstat (the symlink
/// itself) when set, otherwise follow symlinks. Normalizes errors so callers
/// see a consistent set regardless of the platform stat path taken.
fn statForChmod(
    file_path: []const u8,
    no_dereference: bool,
) !struct { mode: std.posix.mode_t, kind: std.Io.File.Kind } {
    if (no_dereference) {
        const info = common.file.FileInfo.lstat(file_path) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                else => err,
            };
        };
        return .{ .mode = info.mode, .kind = info.kind };
    }
    const s = statByPath(file_path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };
    // statByPath follows symlinks, so the resolved kind is never a symlink.
    assert(s.kind != .sym_link);
    return .{ .mode = s.mode, .kind = s.kind };
}

/// Apply the computed mode to a path via the chmod / fchmodat syscall, choosing
/// fchmodat with AT_SYMLINK_NOFOLLOW under no_dereference. Maps syscall errno
/// onto our error set; treats EOPNOTSUPP on symlinks as success per POSIX.
fn applyModeViaSyscall(file_path: []const u8, new_mode: u32, no_dereference: bool) !void {
    assert(file_path.len > 0);
    assert(new_mode <= 0o7777);
    const path_z = try std.posix.toPosixPath(file_path);
    const c = std.c;
    if (no_dereference) {
        const result = c.fchmodat(
            c.AT.FDCWD,
            &path_z,
            @as(c.mode_t, @intCast(new_mode)),
            c.AT.SYMLINK_NOFOLLOW,
        );
        if (result == 0) return;
        const errno = c._errno().*;
        // EOPNOTSUPP is expected on many systems for symlink chmod; accept it.
        if (errno == @intFromEnum(c.E.OPNOTSUPP)) return;
        return switch (errno) {
            @intFromEnum(c.E.NOENT) => error.FileNotFound,
            @intFromEnum(c.E.ACCES) => error.PermissionDenied,
            @intFromEnum(c.E.PERM) => error.PermissionDenied,
            else => error.Unexpected,
        };
    }
    const result = c.chmod(&path_z, @as(c.mode_t, @intCast(new_mode)));
    if (result == 0) return;
    const errno = c._errno().*;
    return switch (errno) {
        @intFromEnum(c.E.NOENT) => error.FileNotFound,
        @intFromEnum(c.E.ACCES) => error.PermissionDenied,
        @intFromEnum(c.E.PERM) => error.PermissionDenied,
        else => error.Unexpected,
    };
}

fn applyModeSpecToFile(
    file_path: []const u8,
    mode_spec: ModeSpec,
    writer: anytype,
    options: ChmodOptions,
) !void {
    assert(mode_spec != .symbolic or mode_spec.symbolic.len > 0);

    const stat_result = try statForChmod(file_path, options.no_dereference);
    const stat_kind = stat_result.kind;
    const old_mode = @as(u32, @intCast(stat_result.mode & 0o7777));

    // Compute new mode based on spec type
    const new_mode = switch (mode_spec) {
        .octal => |m| m.toOctal(),
        .reference => |m| m.toOctal(),
        .symbolic => |mode_str| blk: {
            const is_directory = stat_kind == .directory;
            const new_mode_struct = common.mode.parseSymbolic(
                mode_str,
                old_mode,
                .{ .is_directory = is_directory, .umask = getUmask() },
            ) catch return error.InvalidMode;
            break :blk new_mode_struct.toOctal();
        },
    };
    // Every switch arm computes new_mode via Mode.toOctal, whose u3 class fields
    // plus three special bits cap it at 0o7777; applyModeViaSyscall asserts this
    // too, so document the precondition before the call.
    assert(new_mode <= 0o7777);

    try applyModeViaSyscall(file_path, new_mode, options.no_dereference);

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
fn chmod(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    writer: anytype,
    stderr_writer: anytype,
) !void {
    if (args.len < 2) {
        return error.InvalidArguments;
    }

    const mode_str = args[0];
    const files = args[1..];
    // The guard above rejects args.len < 2, so files = args[1..] is non-empty.
    assert(files.len > 0);
    const options = ChmodOptions{};

    try chmodFiles(io, allocator, mode_str, files, writer, stderr_writer, options);
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
    try testing.expectError(ChmodError.InvalidMode, parseMode(""));
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
test "privileged: applyModeSpecToFile basic functionality" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file_path = "test_file.txt";
            const test_file = try tmp_dir.dir.createFile(testing.io, test_file_path, .{});
            defer test_file.close(testing.io);

            // Test applying mode 644
            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            const mode = Mode.fromOctal(0o644);
            const mode_spec = ModeSpec{ .octal = mode };
            const options = ChmodOptions{ .verbose = true };

            const abs_path = try tmp_dir.dir.realPathFileAlloc(
                testing.io,
                test_file_path,
                inner_allocator,
            );

            try applyModeSpecToFile(abs_path, mode_spec, &stdout_aw.writer, options);

            // Verify the file mode changed
            const stat = try statByPath(abs_path);
            try testing.expectEqual(@as(u32, 0o644), @as(u32, @intCast(stat.mode & 0o777)));

            // Verify verbose output
            try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "mode of") != null);
            try testing.expect(std.mem.find(
                u8,
                stdout_aw.writer.buffered(),
                "test_file.txt",
            ) != null);
        }
    }.testFn);
}

test "privileged: chmodFiles handles multiple files" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_files_rel = [_][]const u8{ "file1.txt", "file2.txt" };
            var test_files_abs = try std.ArrayList([]u8).initCapacity(inner_allocator, 0);
            defer test_files_abs.deinit(inner_allocator);

            for (test_files_rel) |filename| {
                const file = try tmp_dir.dir.createFile(testing.io, filename, .{});
                file.close(testing.io);

                const abs_path = try tmp_dir.dir.realPathFileAlloc(
                    testing.io,
                    filename,
                    inner_allocator,
                );
                try test_files_abs.append(inner_allocator, abs_path);
            }

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            const options = ChmodOptions{ .changes_only = true };

            try chmodFiles(
                testing.io,
                inner_allocator,
                "755",
                test_files_abs.items,
                &stdout_aw.writer,
                &stderr_aw.writer,
                options,
            );

            // Verify both files were processed
            for (test_files_abs.items) |abs_path| {
                const stat = try statByPath(abs_path);
                try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(stat.mode & 0o777)));
            }
        }
    }.testFn);
}

test "chmodFiles handles nonexistent files gracefully" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const nonexistent_files = [_][]const u8{"does_not_exist.txt"};
    const options = ChmodOptions{ .quiet = true };

    // Should return error for nonexistent files, even in quiet mode
    _ = chmodFiles(
        testing.io,
        testing.allocator,
        "644",
        &nonexistent_files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    ) catch |err| {
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

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file_path = "integration_test.txt";
            const test_file = try tmp_dir.dir.createFile(testing.io, test_file_path, .{});
            defer test_file.close(testing.io);

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            const abs_path = try tmp_dir.dir.realPathFileAlloc(
                testing.io,
                test_file_path,
                inner_allocator,
            );

            const args = [_][]const u8{ "755", abs_path };
            try chmod(testing.io, inner_allocator, &args, &stdout_aw.writer, &stderr_aw.writer);

            // Verify the mode was applied
            const stat = try statByPath(abs_path);
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
    // setuid without user execute
    try testing.expectEqualStrings("rwSr-xr-x", &modeToString(0o4655));

    // Test setgid
    try testing.expectEqualStrings("rwxr-sr-x", &modeToString(0o2755));
    // setgid without group execute
    try testing.expectEqualStrings("rwxr-Sr-x", &modeToString(0o2745));

    // Test sticky bit
    try testing.expectEqualStrings("rwxr-xr-t", &modeToString(0o1755));
    // sticky without other execute
    try testing.expectEqualStrings("rwxr-xr-T", &modeToString(0o1754));
}

// Tests: Symbolic mode parsing

// ==================== Symbolic mode tests (via common.mode.parseSymbolic) ====================
// These tests validate the same semantics as the deleted local parser, using the
// shared parser that chmod now delegates to.

fn sym(mode_str: []const u8, base: u32, opts: common.mode.ModeContext) !Mode {
    return common.mode.parseSymbolic(mode_str, base, opts) catch return ChmodError.InvalidMode;
}

test "symbolic: basic additions" {
    try testing.expectEqual(@as(u32, 0o400), (try sym("u+r", 0o000, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o020), (try sym("g+w", 0o000, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o001), (try sym("o+x", 0o000, .{})).toOctal());
}

test "symbolic: basic subtractions" {
    try testing.expectEqual(@as(u32, 0o377), (try sym("u-r", 0o777, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o757), (try sym("g-w", 0o777, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o776), (try sym("o-x", 0o777, .{})).toOctal());
}

test "symbolic: basic assignments" {
    try testing.expectEqual(@as(u32, 0o477), (try sym("u=r", 0o777, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o737), (try sym("g=wx", 0o777, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o770), (try sym("o=", 0o777, .{})).toOctal());
}

test "symbolic: multiple targets" {
    try testing.expectEqual(@as(u32, 0o440), (try sym("ug+r", 0o000, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o755), (try sym("go-w", 0o777, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o755), (try sym("a+x", 0o644, .{})).toOctal());
}

test "symbolic: complex combinations" {
    try testing.expectEqual(@as(u32, 0o700), (try sym("u+rwx", 0o000, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o655), (try sym("u-x", 0o755, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o775), (try sym("g+w", 0o755, .{})).toOctal());
}

test "symbolic: special permission bits" {
    const m1 = try sym("u+s", 0o755, .{});
    try testing.expectEqual(@as(u32, 0o4755), m1.toOctal());
    try testing.expect(m1.setuid);

    const m2 = try sym("g+s", 0o755, .{});
    try testing.expectEqual(@as(u32, 0o2755), m2.toOctal());
    try testing.expect(m2.setgid);

    const m3 = try sym("o+t", 0o755, .{});
    try testing.expectEqual(@as(u32, 0o1755), m3.toOctal());
    try testing.expect(m3.sticky);

    try testing.expectEqual(@as(u32, 0o755), (try sym("u-s", 0o4755, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o755), (try sym("g-s", 0o2755, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o755), (try sym("o-t", 0o1755, .{})).toOctal());

    const m4 = try sym("u+s,g+s", 0o755, .{});
    try testing.expectEqual(@as(u32, 0o6755), m4.toOctal());
    try testing.expect(m4.setuid);
    try testing.expect(m4.setgid);
}

test "symbolic: comma-separated special bits from base 0" {
    const m = try sym("u+s,g+s", 0o000, .{});
    try testing.expectEqual(@as(u32, 0o6000), m.toOctal());

    const m2 = try sym("u=rwx,g=rx,o=r,u+s", 0o000, .{});
    try testing.expectEqual(@as(u32, 0o4754), m2.toOctal());
}

test "symbolic: permission copying" {
    try testing.expectEqual(@as(u32, 0o774), (try sym("g=u", 0o754, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o055), (try sym("o=g", 0o050, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o000), (try sym("u=o", 0o600, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o444), (try sym("ug=o", 0o754, .{})).toOctal());
}

test "symbolic: permission copying with + and - operators" {
    try testing.expectEqual(@as(u32, 0o757), (try sym("o+u", 0o750, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o755), (try sym("g+o", 0o705, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o700), (try sym("g-u", 0o770, .{})).toOctal());
    try testing.expectEqual(@as(u32, 0o750), (try sym("o-g", 0o755, .{})).toOctal());
}

// Tests: X (conditional execute) permission

test "X permission skipped on regular file without existing execute" {
    const m = try sym("a+X", 0o644, .{ .is_directory = false });
    try testing.expectEqual(@as(u32, 0o644), m.toOctal());
}

test "X permission applied on directory" {
    const m = try sym("a+X", 0o644, .{ .is_directory = true });
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "X permission applied when file already has user execute" {
    const m = try sym("a+X", 0o744, .{ .is_directory = false });
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "X permission applied when file already has group execute" {
    const m = try sym("a+X", 0o654, .{ .is_directory = false });
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "X permission applied when file already has other execute" {
    const m = try sym("a+X", 0o645, .{ .is_directory = false });
    try testing.expectEqual(@as(u32, 0o755), m.toOctal());
}

test "X permission skipped without execute context (base 0o644, not dir)" {
    // base_mode has no execute bits and is_directory=false → X is a no-op.
    const m = try sym("a+X", 0o644, .{});
    try testing.expectEqual(@as(u32, 0o644), m.toOctal());
}

test "X permission for specific user class on directory" {
    const m = try sym("u+X", 0o600, .{ .is_directory = true });
    try testing.expectEqual(@as(u32, 0o700), m.toOctal());
}

test "X permission combined with other perms on file without execute" {
    const m = try sym("a+rX", 0o000, .{ .is_directory = false });
    try testing.expectEqual(@as(u32, 0o444), m.toOctal());
}

test "X permission combined with other perms on directory" {
    const m = try sym("a+rX", 0o000, .{ .is_directory = true });
    try testing.expectEqual(@as(u32, 0o555), m.toOctal());
}

// Tests: Recursive operations

test "privileged: recursive chmod on directory structure" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.createDir(testing.io, "subdir", .default_dir);
            try tmp_dir.dir.createDir(testing.io, "subdir/deeper", .default_dir);

            const test_file1 = try tmp_dir.dir.createFile(testing.io, "file1.txt", .{});
            defer test_file1.close(testing.io);

            const test_file2 = try tmp_dir.dir.createFile(testing.io, "subdir/file2.txt", .{});
            defer test_file2.close(testing.io);

            const test_file3 = try tmp_dir.dir.createFile(
                testing.io,
                "subdir/deeper/file3.txt",
                .{},
            );
            defer test_file3.close(testing.io);

            const abs_root = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", inner_allocator);

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            const options = ChmodOptions{ .recursive = true, .verbose = true };
            const files = [_][]const u8{abs_root};

            try chmodFiles(
                testing.io,
                inner_allocator,
                "755",
                &files,
                &stdout_aw.writer,
                &stderr_aw.writer,
                options,
            );

            // Basic verification
            try testing.expect(stdout_aw.writer.buffered().len > 0); // Should have verbose output
        }
    }.testFn);
}

test "privileged: recursive flag processes files and directories" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.createDir(testing.io, "testdir", .default_dir);
            const test_file = try tmp_dir.dir.createFile(testing.io, "testdir/test.txt", .{});
            defer test_file.close(testing.io);

            const abs_dir = try tmp_dir.dir.realPathFileAlloc(
                testing.io,
                "testdir",
                inner_allocator,
            );

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            const options = ChmodOptions{ .recursive = true, .changes_only = true };
            const files = [_][]const u8{abs_dir};

            try chmodFiles(
                testing.io,
                inner_allocator,
                "644",
                &files,
                &stdout_aw.writer,
                &stderr_aw.writer,
                options,
            );

            // The test passes if no errors are thrown
        }
    }.testFn);
}

// Tests: Verbose, changes, and silent flags

test "privileged: verbose flag outputs changes" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file = try tmp_dir.dir.createFile(testing.io, "test_verbose.txt", .{});
            defer test_file.close(testing.io);

            const abs_path = try tmp_dir.dir.realPathFileAlloc(
                testing.io,
                "test_verbose.txt",
                inner_allocator,
            );

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            const options = ChmodOptions{ .verbose = true };
            const files = [_][]const u8{abs_path};

            try chmodFiles(
                testing.io,
                inner_allocator,
                "755",
                &files,
                &stdout_aw.writer,
                &stderr_aw.writer,
                options,
            );

            // Should have verbose output
            try testing.expect(stdout_aw.writer.buffered().len > 0);
            try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "mode of") != null);
            try testing.expect(std.mem.find(
                u8,
                stdout_aw.writer.buffered(),
                "changed from",
            ) != null);
        }
    }.testFn);
}

test "privileged: changes flag only outputs when mode changes" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file = try tmp_dir.dir.createFile(testing.io, "test_changes.txt", .{});
            defer test_file.close(testing.io);

            const abs_path = try tmp_dir.dir.realPathFileAlloc(
                testing.io,
                "test_changes.txt",
                inner_allocator,
            );

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            const options = ChmodOptions{ .changes_only = true };
            const files = [_][]const u8{abs_path};

            try chmodFiles(
                testing.io,
                inner_allocator,
                "755",
                &files,
                &stdout_aw.writer,
                &stderr_aw.writer,
                options,
            );

            // Should have output when mode changes
            try testing.expect(stdout_aw.writer.buffered().len > 0);

            // Clear buffer and apply same mode again
            stdout_aw.deinit();
            stdout_aw = .init(inner_allocator);
            stderr_aw.deinit();
            stderr_aw = .init(inner_allocator);
            try chmodFiles(
                testing.io,
                inner_allocator,
                "755",
                &files,
                &stdout_aw.writer,
                &stderr_aw.writer,
                options,
            );

            try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
        }
    }.testFn);
}

test "quiet flag suppresses error messages" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const nonexistent_files = [_][]const u8{"nonexistent_file.txt"};
    const options = ChmodOptions{ .quiet = true };

    // Should return error for nonexistent files but produce no error output due to quiet mode
    _ = chmodFiles(
        testing.io,
        testing.allocator,
        "755",
        &nonexistent_files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    ) catch |err| {
        try testing.expect(err == ChmodError.FileOperationFailed);
        // Should produce no output due to quiet mode
        try testing.expectEqual(@as(usize, 0), stdout_aw.writer.buffered().len);
        try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
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

// Tests: Non-octal digit detection

test "hasNonOctalDigits detects 8 and 9 in mode string" {
    try testing.expect(hasNonOctalDigits("899"));
    try testing.expect(hasNonOctalDigits("789"));
}

test "hasNonOctalDigits returns false for valid octal modes" {
    try testing.expect(!hasNonOctalDigits("755"));
    try testing.expect(!hasNonOctalDigits("644"));
}

test "hasNonOctalDigits returns false for symbolic modes" {
    try testing.expect(!hasNonOctalDigits("u+x"));
    try testing.expect(!hasNonOctalDigits("go-w"));
    try testing.expect(!hasNonOctalDigits("a=rwx"));
}

test "non-octal digit warning is printed to stderr" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const nonexistent_files = [_][]const u8{"does_not_exist.txt"};
    const options = ChmodOptions{};

    // Mode "899" contains non-octal digits; chmodFiles should warn on stderr
    _ = chmodFiles(
        testing.io,
        testing.allocator,
        "899",
        &nonexistent_files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    ) catch {};

    // Should contain the non-octal warning
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "non-octal digits") != null);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "899") != null);
}

test "no non-octal digit warning for valid octal mode" {
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const nonexistent_files = [_][]const u8{"does_not_exist.txt"};
    const options = ChmodOptions{};

    // Mode "755" is valid octal; should not produce a non-octal warning
    _ = chmodFiles(
        testing.io,
        testing.allocator,
        "755",
        &nonexistent_files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    ) catch {};

    // Should NOT contain non-octal warning (may contain other error messages)
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "non-octal digits") == null);
}

// Tests: -H, -L, -P symlink traversal flags

test "parse -H flag" {
    const args = [_][]const u8{ "-H", "755", "file.txt" };
    const parsed = try common.argparse.ArgParser.parse(ChmodArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.H);
    try testing.expect(!parsed.L);
    try testing.expect(!parsed.P);
}

test "parse -L flag" {
    const args = [_][]const u8{ "-L", "755", "file.txt" };
    const parsed = try common.argparse.ArgParser.parse(ChmodArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(!parsed.H);
    try testing.expect(parsed.L);
    try testing.expect(!parsed.P);
}

test "parse -P flag" {
    const args = [_][]const u8{ "-P", "755", "file.txt" };
    const parsed = try common.argparse.ArgParser.parse(ChmodArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(!parsed.H);
    try testing.expect(!parsed.L);
    try testing.expect(parsed.P);
}

test "ChmodOptions has symlink traversal fields" {
    const options = ChmodOptions{
        .traverse_cmdline_symlinks = true,
        .traverse_all_symlinks = false,
        .no_traverse_symlinks = false,
    };
    try testing.expect(options.traverse_cmdline_symlinks);
    try testing.expect(!options.traverse_all_symlinks);
    try testing.expect(!options.no_traverse_symlinks);
}

test "ChmodOptions symlink traversal defaults to false" {
    const options = ChmodOptions{};
    try testing.expect(!options.traverse_cmdline_symlinks);
    try testing.expect(!options.traverse_all_symlinks);
    try testing.expect(!options.no_traverse_symlinks);
}

test "chmod: -h flag is parsed as no_dereference" {
    const args = [_][]const u8{ "-h", "755", "file.txt" };
    const parsed = try common.argparse.ArgParser.parse(ChmodArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    // -h should map to no_dereference, not help
    try testing.expect(parsed.no_dereference);
    try testing.expect(!parsed.help);
}

test "chmod: --help still works as long-only flag" {
    const args = [_][]const u8{"--help"};
    const parsed = try common.argparse.ArgParser.parse(ChmodArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.help);
}

test "ChmodOptions has no_dereference field" {
    const options = ChmodOptions{
        .no_dereference = true,
    };
    try testing.expect(options.no_dereference);
}

// Tests for new flags

test "chmod --preserve-root blocks recursive on /" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--preserve-root", "-R", "755", "/" };
    const exit_code = try runChmod(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), exit_code);
    try testing.expect(std.mem.find(
        u8,
        stderr_aw.writer.buffered(),
        "dangerous to operate recursively on '/'",
    ) != null);
}

test "chmod --preserve-root allows non-recursive on /" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Without -R, --preserve-root should not block
    const args = [_][]const u8{ "--preserve-root", "755", "/" };
    const exit_code = try runChmod(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Should fail with permission error, not preserve-root error
    try testing.expect(std.mem.find(
        u8,
        stderr_aw.writer.buffered(),
        "dangerous to operate recursively",
    ) == null);
    _ = exit_code;
}

test "chmod --dereference flag is accepted" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--dereference", "--help" };
    const exit_code = try runChmod(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "chmod --no-preserve-root flag is accepted" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--no-preserve-root", "--help" };
    const exit_code = try runChmod(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "chmod -C flag is accepted (ACL no-op)" {
    const args = [_][]const u8{ "-C", "755", "file.txt" };
    const parsed = try common.argparse.ArgParser.parse(ChmodArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.acl_check);
}

test "chmod -E flag is accepted (ACL no-op)" {
    const args = [_][]const u8{ "-E", "755", "file.txt" };
    const parsed = try common.argparse.ArgParser.parse(ChmodArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.acl_stdin);
}

test "chmod -i flag is accepted (ACL no-op)" {
    const args = [_][]const u8{ "-i", "755", "file.txt" };
    const parsed = try common.argparse.ArgParser.parse(ChmodArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.acl_remove_inherited);
}

test "chmod -I flag is accepted (ACL no-op)" {
    const args = [_][]const u8{ "-I", "755", "file.txt" };
    const parsed = try common.argparse.ArgParser.parse(ChmodArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.acl_remove_all_inherited);
}

test "chmod -N flag is accepted (ACL no-op)" {
    const args = [_][]const u8{ "-N", "755", "file.txt" };
    const parsed = try common.argparse.ArgParser.parse(ChmodArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.acl_remove);
}

test "chmod help text includes new flags" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    try printHelp(testing.allocator, &stdout_aw.writer);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--preserve-root") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--no-preserve-root") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--dereference") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "ACL") != null);
}

test "chmod ChmodOptions has preserve_root field" {
    const options = ChmodOptions{
        .preserve_root = true,
    };
    try testing.expect(options.preserve_root);
}

test "chmod ChmodOptions preserve_root defaults to false" {
    const options = ChmodOptions{};
    try testing.expect(!options.preserve_root);
}

// Tests: Sticky bit should apply regardless of who-bits (POSIX bug)

test "a+t sets sticky bit on file with mode 0644" {
    const m = try sym("a+t", 0o644, .{});
    try testing.expectEqual(@as(u32, 0o1644), m.toOctal());
    try testing.expect(m.sticky);
}

test "u+t sets sticky bit on file with mode 0644" {
    const m = try sym("u+t", 0o644, .{});
    try testing.expectEqual(@as(u32, 0o1644), m.toOctal());
    try testing.expect(m.sticky);
}

test "g+t sets sticky bit on file with mode 0644" {
    const m = try sym("g+t", 0o644, .{});
    try testing.expectEqual(@as(u32, 0o1644), m.toOctal());
    try testing.expect(m.sticky);
}

test "o+t sets sticky bit on file with mode 0644" {
    const m = try sym("o+t", 0o644, .{});
    try testing.expectEqual(@as(u32, 0o1644), m.toOctal());
    try testing.expect(m.sticky);
}

test "a-t removes sticky bit from file with mode 01644" {
    const m = try sym("a-t", 0o1644, .{});
    try testing.expectEqual(@as(u32, 0o644), m.toOctal());
    try testing.expect(!m.sticky);
}

test "u-t removes sticky bit from file with mode 01644" {
    const m = try sym("u-t", 0o1644, .{});
    try testing.expectEqual(@as(u32, 0o644), m.toOctal());
    try testing.expect(!m.sticky);
}

// Tests: AccessDenied from statFile should propagate, not substitute zeroed Stat

test "chmod stat AccessDenied produces correct Permission denied message" {
    // Skip if running as root (root bypasses permission checks)
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a subdirectory with a file inside
    try tmp_dir.dir.createDir(testing.io, "noaccess", .default_dir);
    const inner_file = try tmp_dir.dir.createFile(testing.io, "noaccess/target.txt", .{});
    inner_file.close(testing.io);

    // Get the full path to the file inside
    const dir_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);
    const inner_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/noaccess/target.txt",
        .{dir_path},
    );
    defer testing.allocator.free(inner_path);

    // Remove execute permission from the directory, making the file inaccessible
    const noaccess_path = try std.fmt.allocPrint(testing.allocator, "{s}/noaccess", .{dir_path});
    defer testing.allocator.free(noaccess_path);
    const noaccess_z = std.posix.toPosixPath(noaccess_path) catch return;
    _ = std.c.chmod(&noaccess_z, 0o000);

    // Ensure we restore permissions for cleanup
    defer _ = std.c.chmod(&noaccess_z, 0o755);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const files = [_][]const u8{inner_path};
    const options = ChmodOptions{};

    // chmodFiles should return FileOperationFailed since the file is inaccessible
    _ = chmodFiles(
        testing.io,
        testing.allocator,
        "755",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    ) catch |err| {
        try testing.expect(err == ChmodError.FileOperationFailed);

        // BUG: When statFile returns AccessDenied, the code substitutes a zeroed
        // Stat instead of propagating the error. This causes the error to flow
        // through the chmod() syscall path instead, which returns PermissionDenied.
        // posixErrorString maps both AccessDenied and PermissionDenied -> "Permission denied".
        try testing.expect(std.mem.find(
            u8,
            stderr_aw.writer.buffered(),
            "Permission denied",
        ) != null);
        return;
    };

    // Should not reach here -- chmodFiles should have returned an error
    try testing.expect(false);
}

test "chmod stat AccessDenied returns AccessDenied not PermissionDenied" {
    // Skip if running as root (root bypasses permission checks)
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a subdirectory with a file inside
    try tmp_dir.dir.createDir(testing.io, "noaccess", .default_dir);
    const inner_file = try tmp_dir.dir.createFile(testing.io, "noaccess/target.txt", .{});
    inner_file.close(testing.io);

    // Get the full path to the file inside
    const dir_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);
    const inner_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/noaccess/target.txt",
        .{dir_path},
    );
    defer testing.allocator.free(inner_path);

    // Remove execute permission from the directory
    const noaccess_path = try std.fmt.allocPrint(testing.allocator, "{s}/noaccess", .{dir_path});
    defer testing.allocator.free(noaccess_path);
    const noaccess_z = std.posix.toPosixPath(noaccess_path) catch return;
    _ = std.c.chmod(&noaccess_z, 0o000);

    // Ensure we restore permissions for cleanup
    defer _ = std.c.chmod(&noaccess_z, 0o755);

    var output_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output_aw.deinit();

    const mode = Mode.fromOctal(0o755);
    const mode_spec = ModeSpec{ .octal = mode };
    const options = ChmodOptions{};

    // BUG: applyModeSpecToFile should propagate error.AccessDenied from statFile,
    // but instead it substitutes a zeroed Stat (mode=0) and continues. The
    // subsequent chmod() syscall also fails, but returns error.PermissionDenied
    // instead of the original error.AccessDenied.
    // This test expects AccessDenied to be propagated directly from stat.
    const result = applyModeSpecToFile(inner_path, mode_spec, &output_aw.writer, options);
    try testing.expectError(error.AccessDenied, result);
}

// Tests: parseMode returns correct ModeSpec variant for symbolic vs octal input
// Safety-net tests to ensure the working code path is preserved during dead-code cleanup

test "parseMode with symbolic string validates without error" {
    // parseMode("u+x") validates the symbolic string via common.mode.parseSymbolic.
    // Returns a placeholder Mode (base 0) since actual application is per-file.
    const mode = try parseMode("u+x");
    // Placeholder: symbolic modes return fromOctal(0) during pre-validation.
    _ = mode;
}

test "parseMode with octal string returns correct mode" {
    // Verify the octal path still works as expected
    const mode = try parseMode("0644");
    try testing.expectEqual(@as(u32, 0o644), mode.toOctal());
}

// =============================================================================
// Behavioral tests: verify chmod ACTUALLY CHANGES FILE PERMISSIONS on disk
// =============================================================================
//
// These tests create real temp files, apply chmod via chmodFiles or runChmod,
// then stat the file to verify the mode changed. This covers the audit finding
// (F69) that existing unit tests only check parsed struct fields.

/// Helper: set a file's mode via libc chmod, for test setup
fn setFileModeOctal(path: []const u8, mode_val: u32) !void {
    const path_z = try std.posix.toPosixPath(path);
    const result = std.c.chmod(&path_z, @as(std.c.mode_t, @intCast(mode_val)));
    if (result != 0) return error.ChmodFailed;
}

fn getFileMode(path: []const u8) !u32 {
    const stat = try statByPath(path);
    return @as(u32, @intCast(stat.mode & 0o7777));
}

test "behavioral: chmod 755 actually sets mode 0o755" {
    // Skip if running as root (root may produce different behavior)
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test755.txt", .{});
    test_file.close(testing.io);

    const abs_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "test755.txt",
        testing.allocator,
    );
    defer testing.allocator.free(abs_path);

    // Set initial mode to 0o644
    try setFileModeOctal(abs_path, 0o644);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const files = [_][]const u8{abs_path};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "755",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{},
    );

    const actual_mode = try getFileMode(abs_path);
    try testing.expectEqual(@as(u32, 0o755), actual_mode);
}

test "behavioral: chmod u+x from 644 sets mode 0o744" {
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test_uplusx.txt", .{});
    test_file.close(testing.io);

    const abs_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "test_uplusx.txt",
        testing.allocator,
    );
    defer testing.allocator.free(abs_path);

    try setFileModeOctal(abs_path, 0o644);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const files = [_][]const u8{abs_path};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "u+x",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{},
    );

    const actual_mode = try getFileMode(abs_path);
    try testing.expectEqual(@as(u32, 0o744), actual_mode);
}

test "behavioral: chmod g+w from 644 sets mode 0o664" {
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test_gplusw.txt", .{});
    test_file.close(testing.io);

    const abs_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "test_gplusw.txt",
        testing.allocator,
    );
    defer testing.allocator.free(abs_path);

    try setFileModeOctal(abs_path, 0o644);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const files = [_][]const u8{abs_path};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "g+w",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{},
    );

    const actual_mode = try getFileMode(abs_path);
    try testing.expectEqual(@as(u32, 0o664), actual_mode);
}

test "behavioral: chmod o-r from 644 sets mode 0o640" {
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test_ominusr.txt", .{});
    test_file.close(testing.io);

    const abs_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "test_ominusr.txt",
        testing.allocator,
    );
    defer testing.allocator.free(abs_path);

    try setFileModeOctal(abs_path, 0o644);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const files = [_][]const u8{abs_path};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "o-r",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{},
    );

    const actual_mode = try getFileMode(abs_path);
    try testing.expectEqual(@as(u32, 0o640), actual_mode);
}

test "behavioral: chmod a+x from 644 sets mode 0o755" {
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test_aplusx.txt", .{});
    test_file.close(testing.io);

    const abs_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "test_aplusx.txt",
        testing.allocator,
    );
    defer testing.allocator.free(abs_path);

    try setFileModeOctal(abs_path, 0o644);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const files = [_][]const u8{abs_path};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "a+x",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{},
    );

    const actual_mode = try getFileMode(abs_path);
    try testing.expectEqual(@as(u32, 0o755), actual_mode);
}

test "behavioral: chmod u=rwx,g=rx,o=r sets mode 0o754" {
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test_complex.txt", .{});
    test_file.close(testing.io);

    const abs_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "test_complex.txt",
        testing.allocator,
    );
    defer testing.allocator.free(abs_path);

    try setFileModeOctal(abs_path, 0o000);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const files = [_][]const u8{abs_path};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "u=rwx,g=rx,o=r",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{},
    );

    const actual_mode = try getFileMode(abs_path);
    try testing.expectEqual(@as(u32, 0o754), actual_mode);
}

test "behavioral: chmod +t on directory sets sticky bit" {
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(testing.io, "stickydir", .default_dir);

    const abs_path = try tmp_dir.dir.realPathFileAlloc(testing.io, "stickydir", testing.allocator);
    defer testing.allocator.free(abs_path);

    try setFileModeOctal(abs_path, 0o755);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const files = [_][]const u8{abs_path};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "+t",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{},
    );

    const actual_mode = try getFileMode(abs_path);
    // Sticky bit (0o1000) should be set, basic perms should be preserved
    try testing.expect((actual_mode & 0o1000) != 0);
    try testing.expectEqual(@as(u32, 0o1755), actual_mode);
}

test "behavioral: chmod 4755 sets setuid bit" {
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test_setuid.txt", .{});
    test_file.close(testing.io);

    const abs_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "test_setuid.txt",
        testing.allocator,
    );
    defer testing.allocator.free(abs_path);

    try setFileModeOctal(abs_path, 0o644);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const files = [_][]const u8{abs_path};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "4755",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{},
    );

    const actual_mode = try getFileMode(abs_path);
    // Setuid bit (0o4000) should be set
    try testing.expect((actual_mode & 0o4000) != 0);
    try testing.expectEqual(@as(u32, 0o4755), actual_mode);
}

test "behavioral: chmod -w via runChmod removes write permission" {
    // BUG: chmod -w file should remove write permission from all users,
    // but the argparser consumes -w as a flag (UnknownFlag error) instead
    // of treating it as a symbolic mode string.
    // This test documents the bug and will FAIL until fixed.
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test_minusw.txt", .{});
    test_file.close(testing.io);

    const abs_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "test_minusw.txt",
        testing.allocator,
    );
    defer testing.allocator.free(abs_path);

    try setFileModeOctal(abs_path, 0o644);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // chmod -w file should succeed with exit code 0
    const args = [_][]const u8{ "-w", abs_path };
    const exit_code = try runChmod(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Should succeed (exit code 0), not fail as "invalid argument"
    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should have removed write permission: 0o644 -> 0o444
    const actual_mode = try getFileMode(abs_path);
    try testing.expectEqual(@as(u32, 0o444), actual_mode);
}

test "chmod: -R -P should not follow symlinks during traversal" {
    // GNU chmod -R does not follow symlinks during recursive traversal.
    // When -P is active (default for -R), symlinks encountered inside a
    // directory should be skipped — chmod must NOT modify the target file's
    // permissions through the symlink.
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target file OUTSIDE the directory tree being chmod'd
    const target_file = try tmp_dir.dir.createFile(testing.io, "outside_target.txt", .{});
    target_file.close(testing.io);

    // Create the directory to recurse into
    try tmp_dir.dir.createDir(testing.io, "mydir", .default_dir);
    var mydir = try tmp_dir.dir.openDir(testing.io, "mydir", .{});
    defer mydir.close(testing.io);

    // Create a regular file inside mydir
    const inner_file = try mydir.createFile(testing.io, "regular.txt", .{});
    inner_file.close(testing.io);

    // Create a symlink inside mydir pointing to the outside target
    mydir.symLink(
        testing.io,
        "../outside_target.txt",
        "link_to_outside",
        .{},
    ) catch |err| switch (err) {
        error.AccessDenied => return, // symlinks not supported
        else => return,
    };

    const mydir_abs = try tmp_dir.dir.realPathFileAlloc(testing.io, "mydir", testing.allocator);
    defer testing.allocator.free(mydir_abs);
    const target_abs = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "outside_target.txt",
        testing.allocator,
    );
    defer testing.allocator.free(target_abs);

    // Set known modes: target=0o644, regular=0o644
    try setFileModeOctal(target_abs, 0o644);

    const regular_abs = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "mydir/regular.txt",
        testing.allocator,
    );
    defer testing.allocator.free(regular_abs);
    try setFileModeOctal(regular_abs, 0o644);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // chmod -R -P 755 mydir — should NOT follow symlinks during traversal
    const files = [_][]const u8{mydir_abs};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "755",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{ .recursive = true, .no_traverse_symlinks = true },
    );

    // regular.txt inside mydir should be 755
    const regular_mode = try getFileMode(regular_abs);
    try testing.expectEqual(@as(u32, 0o755), regular_mode);

    // outside_target.txt should still be 0o644 — the symlink must not
    // have been followed to chmod the target
    const target_mode = try getFileMode(target_abs);
    try testing.expectEqual(@as(u32, 0o644), target_mode);
}

// ==================== I3: umask bypass tests ====================
// Umask tests: now pass umask via ModeContext instead of mutating process state.
test "symbolic: +x without who respects umask" {
    // umask 0o033: user-x unmasked, group/other-x masked
    const m = try sym("+x", 0o000, .{ .umask = 0o033 });
    try testing.expectEqual(@as(u32, 0o100), m.toOctal());
}

test "symbolic: a+x with explicit 'a' ignores umask" {
    const m = try sym("a+x", 0o000, .{ .umask = 0o033 });
    try testing.expectEqual(@as(u32, 0o111), m.toOctal());
}

test "symbolic: -x without who removes all execute regardless of umask" {
    const m = try sym("-x", 0o111, .{ .umask = 0o033 });
    try testing.expectEqual(@as(u32, 0o000), m.toOctal());
}

test "symbolic: +rw without who masks bits blocked by umask 022" {
    // umask 0o022: g-write and o-write masked
    const m = try sym("+rw", 0o000, .{ .umask = 0o022 });
    try testing.expectEqual(@as(u32, 0o644), m.toOctal());
}

// ==================== I4: chmod -x flag collision tests ====================

test "behavioral: chmod -x via runChmod removes execute permission" {
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile(testing.io, "test_minusx.txt", .{});
    test_file.close(testing.io);

    const abs_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "test_minusx.txt",
        testing.allocator,
    );
    defer testing.allocator.free(abs_path);

    try setFileModeOctal(abs_path, 0o755);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-x", abs_path };
    const exit_code = try runChmod(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    // 0o755 - execute from all = 0o644
    const actual_mode = try getFileMode(abs_path);
    try testing.expectEqual(@as(u32, 0o644), actual_mode);
}

// =============================================================================
// Characterization tests: lock in recursive-traversal behavior for the
// upcoming chmodRecursive -> bounded walker migration.
//
// These tests assert on-disk file modes after a real recursive chmod run.
// They are behavior-PRESERVING: they pass on the current recursive code and
// must keep passing once chmodRecursive is replaced by the walker driver loop.
// Each test exercises a distinct invariant that a wrong rewrite would break.
//
// They follow the non-privileged behavioral-test pattern already used by
// "chmod: -R -P should not follow symlinks during traversal": skip under root,
// create real temp files, run chmodFiles, then stat the results.
// =============================================================================

test "char: -R applies mode to every entry across a multi-level tree" {
    // Guards: recursive descent must reach files at every depth, not just the
    // top level. A rewrite that fails to descend would leave deep files at
    // their original mode.
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(testing.io, "a", .default_dir);
    try tmp_dir.dir.createDir(testing.io, "a/b", .default_dir);
    try tmp_dir.dir.createDir(testing.io, "a/b/c", .default_dir);

    const f0 = try tmp_dir.dir.createFile(testing.io, "a/top.txt", .{});
    f0.close(testing.io);
    const f1 = try tmp_dir.dir.createFile(testing.io, "a/b/mid.txt", .{});
    f1.close(testing.io);
    const f2 = try tmp_dir.dir.createFile(testing.io, "a/b/c/deep.txt", .{});
    f2.close(testing.io);

    const paths = [_][]const u8{
        "a/top.txt",
        "a/b/mid.txt",
        "a/b/c/deep.txt",
        "a",
        "a/b",
        "a/b/c",
    };
    var abs_paths: [paths.len][:0]u8 = undefined;
    for (paths, 0..) |rel, idx| {
        abs_paths[idx] = try tmp_dir.dir.realPathFileAlloc(testing.io, rel, testing.allocator);
    }
    defer for (abs_paths) |p| testing.allocator.free(p);

    // Start every entry at a mode distinct from the target so a no-op rewrite
    // is detectable.
    for (abs_paths) |p| try setFileModeOctal(p, 0o700);

    const root_abs = try tmp_dir.dir.realPathFileAlloc(testing.io, "a", testing.allocator);
    defer testing.allocator.free(root_abs);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const files = [_][]const u8{root_abs};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "750",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{ .recursive = true },
    );

    // Every file and every directory in the tree must now be 0o750.
    for (abs_paths) |p| {
        try testing.expectEqual(@as(u32, 0o750), try getFileMode(p));
    }
}

test "char: post-order applies mode to leaf, child, and parent in one run" {
    // Guards the post-order / open-first invariant: a directory's contents must
    // be chmod'd BEFORE the directory itself. The target mode 0o600 strips the
    // owner-search bit (x) from directories, so path-based descent through a
    // parent is impossible once that parent has been chmod'd. This is the teeth
    // of the test:
    //   * A correct post-order walk reaches the deepest leaf first, chmods it,
    //     then the child dir, then the parent. Every entry is processed while
    //     its ancestors still have x, so the leaf ends at 0o600.
    //   * A broken pre-order walk chmods the parent to 0o600 first, immediately
    //     locking itself out of "parent/child/leaf.txt"; the leaf is never
    //     reached and stays at its distinct starting mode (0o644).
    // Removing the owner search bit blocks traversal even for a non-root process
    // (verified: a uid!=0 process cannot path-descend through a dir lacking x),
    // so this discriminates the two orderings without root. After the run we
    // restore traversal bits on the directories so we (and cleanup) can re-stat
    // the leaf; the leaf is a file, so restoring dir bits does not perturb it.
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(testing.io, "parent", .default_dir);
    try tmp_dir.dir.createDir(testing.io, "parent/child", .default_dir);
    const leaf = try tmp_dir.dir.createFile(testing.io, "parent/child/leaf.txt", .{});
    leaf.close(testing.io);

    const parent_abs = try tmp_dir.dir.realPathFileAlloc(testing.io, "parent", testing.allocator);
    defer testing.allocator.free(parent_abs);
    const child_abs = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "parent/child",
        testing.allocator,
    );
    defer testing.allocator.free(child_abs);
    const leaf_abs = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "parent/child/leaf.txt",
        testing.allocator,
    );
    defer testing.allocator.free(leaf_abs);

    // Directories start traversable (0o700). The leaf starts at 0o644 so the
    // 0o600 target is a real, detectable change distinct from any starting mode.
    try setFileModeOctal(parent_abs, 0o700);
    try setFileModeOctal(child_abs, 0o700);
    try setFileModeOctal(leaf_abs, 0o644);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const files = [_][]const u8{parent_abs};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "600",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{ .recursive = true },
    );

    // Restore directory traversal so we can re-stat the leaf and so cleanup can
    // recurse; restoring dir bits cannot change the leaf's own mode.
    try setFileModeOctal(parent_abs, 0o700);
    try setFileModeOctal(child_abs, 0o700);

    // The deepest leaf must carry 0o600. A pre-order rewrite would have locked
    // itself out after chmod'ing the parent and left the leaf at 0o644.
    try testing.expectEqual(@as(u32, 0o600), try getFileMode(leaf_abs));
}

test "char: -L descends symlinked directory and chmods its contents" {
    // Guards: under -L (traverse_all_symlinks) a symlink that points at a
    // directory must be descended and every entry under the target receives
    // the mode. A rewrite that ignored -L would leave the target's contents
    // unchanged.
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Real directory outside the walked tree, containing a file.
    try tmp_dir.dir.createDir(testing.io, "real_target", .default_dir);
    const inside = try tmp_dir.dir.createFile(testing.io, "real_target/inside.txt", .{});
    inside.close(testing.io);

    // The tree we walk; contains a symlink to real_target.
    try tmp_dir.dir.createDir(testing.io, "tree", .default_dir);
    var tree = try tmp_dir.dir.openDir(testing.io, "tree", .{});
    defer tree.close(testing.io);
    tree.symLink(testing.io, "../real_target", "link_to_dir", .{}) catch |err| switch (err) {
        error.AccessDenied => return,
        else => return,
    };

    const inside_abs = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "real_target/inside.txt",
        testing.allocator,
    );
    defer testing.allocator.free(inside_abs);
    const tree_abs = try tmp_dir.dir.realPathFileAlloc(testing.io, "tree", testing.allocator);
    defer testing.allocator.free(tree_abs);

    try setFileModeOctal(inside_abs, 0o700);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Target 0o750 keeps directories owner-traversable so the non-root test
    // process can stat results after the descent into the symlinked directory.
    const files = [_][]const u8{tree_abs};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "750",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{ .recursive = true, .traverse_all_symlinks = true },
    );

    // The file reached only by following the symlinked directory must be 0o750.
    try testing.expectEqual(@as(u32, 0o750), try getFileMode(inside_abs));
}

test "char: -P leaves symlink target unchanged but chmods sibling files" {
    // Guards: under -P (default) symlinks are not followed, so the target keeps
    // its mode, while a real sibling file in the same directory IS chmod'd.
    // Distinct target/sibling modes prevent a default-value trap.
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const target = try tmp_dir.dir.createFile(testing.io, "outside.txt", .{});
    target.close(testing.io);

    try tmp_dir.dir.createDir(testing.io, "dir", .default_dir);
    var dir = try tmp_dir.dir.openDir(testing.io, "dir", .{});
    defer dir.close(testing.io);
    const sibling = try dir.createFile(testing.io, "sibling.txt", .{});
    sibling.close(testing.io);
    dir.symLink(testing.io, "../outside.txt", "thelink", .{}) catch |err| switch (err) {
        error.AccessDenied => return,
        else => return,
    };

    const target_abs = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "outside.txt",
        testing.allocator,
    );
    defer testing.allocator.free(target_abs);
    const sibling_abs = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "dir/sibling.txt",
        testing.allocator,
    );
    defer testing.allocator.free(sibling_abs);
    const dir_abs = try tmp_dir.dir.realPathFileAlloc(testing.io, "dir", testing.allocator);
    defer testing.allocator.free(dir_abs);

    try setFileModeOctal(target_abs, 0o600);
    try setFileModeOctal(sibling_abs, 0o700);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Target 0o750 keeps "dir" owner-traversable for result verification; the
    // sibling starts at 0o700 so the change is detectable, and the symlink
    // target starts at 0o600 so a wrongly-followed symlink would be visible.
    const files = [_][]const u8{dir_abs};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "750",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{ .recursive = true, .no_traverse_symlinks = true },
    );

    // Sibling must change; symlink target must be untouched.
    try testing.expectEqual(@as(u32, 0o750), try getFileMode(sibling_abs));
    try testing.expectEqual(@as(u32, 0o600), try getFileMode(target_abs));
}

test "char: deep tree (~100 levels) completes without stack overflow" {
    // Guards: a ~100-level nested directory chain must be fully chmod'd. This
    // is the core motivation for the walker migration (iterative bound vs.
    // per-level recursion). We verify the deepest file received the mode.
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const depth: usize = 100;

    // Build the nested path "d/d/d/.../d" iteratively.
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(testing.allocator);
    var level: usize = 0;
    while (level < depth) : (level += 1) {
        if (level != 0) try path_buf.append(testing.allocator, '/');
        try path_buf.append(testing.allocator, 'd');
        try tmp_dir.dir.createDir(testing.io, path_buf.items, .default_dir);
    }
    // Place a file at the bottom.
    try path_buf.appendSlice(testing.allocator, "/bottom.txt");
    const bottom = try tmp_dir.dir.createFile(testing.io, path_buf.items, .{});
    bottom.close(testing.io);

    const bottom_abs = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        path_buf.items,
        testing.allocator,
    );
    defer testing.allocator.free(bottom_abs);
    try setFileModeOctal(bottom_abs, 0o700);

    const root_abs = try tmp_dir.dir.realPathFileAlloc(testing.io, "d", testing.allocator);
    defer testing.allocator.free(root_abs);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Target 0o750 keeps every level owner-traversable so the deepest file can
    // be stat'd afterward; the bottom file starts at 0o700 to make the change
    // detectable.
    const files = [_][]const u8{root_abs};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "750",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{ .recursive = true },
    );

    // The file 100 levels deep must have received the new mode.
    try testing.expectEqual(@as(u32, 0o750), try getFileMode(bottom_abs));
}

test "char: symlink cycle does not cause an infinite loop" {
    // Guards: a symlink pointing back into an ancestor directory must not cause
    // chmod -R to loop forever. We use the default -P policy (symlinks not
    // followed) so the cycle is inert, plus assert the real file still gets the
    // mode. The walker always runs chmod with cycle_mode = .ancestors (not
    // conditioned on -L), so an ancestor loop under -L surfaces as a
    // re-entrant error.DirectoryCycle and terminates rather than silently
    // deduping; here we lock in that -R completes and the run terminates.
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(testing.io, "root", .default_dir);
    try tmp_dir.dir.createDir(testing.io, "root/sub", .default_dir);
    var sub = try tmp_dir.dir.openDir(testing.io, "root/sub", .{});
    defer sub.close(testing.io);
    const f = try sub.createFile(testing.io, "real.txt", .{});
    f.close(testing.io);
    // Symlink that points back up to the walk root, forming a cycle.
    sub.symLink(testing.io, "../../root", "loop", .{}) catch |err| switch (err) {
        error.AccessDenied => return,
        else => return,
    };

    const real_abs = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "root/sub/real.txt",
        testing.allocator,
    );
    defer testing.allocator.free(real_abs);
    const root_abs = try tmp_dir.dir.realPathFileAlloc(testing.io, "root", testing.allocator);
    defer testing.allocator.free(root_abs);

    try setFileModeOctal(real_abs, 0o700);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -R with default -P: must terminate, and the real file must be chmod'd.
    // Target 0o750 keeps directories owner-traversable for verification.
    const files = [_][]const u8{root_abs};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "750",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{ .recursive = true },
    );

    try testing.expectEqual(@as(u32, 0o750), try getFileMode(real_abs));
}

test "char: wide directory - every entry receives the mode" {
    // Guards: a directory with many entries must have ALL of them chmod'd, not
    // just the first few. A rewrite that mishandled iterator batching would
    // miss some entries.
    if (std.c.getuid() == 0) return;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(testing.io, "wide", .default_dir);
    var wide = try tmp_dir.dir.openDir(testing.io, "wide", .{});
    defer wide.close(testing.io);

    const count: usize = 64;
    var name_buf: [32]u8 = undefined;
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "f{d}.txt", .{idx});
        const file = try wide.createFile(testing.io, name, .{});
        file.close(testing.io);
    }

    const wide_abs = try tmp_dir.dir.realPathFileAlloc(testing.io, "wide", testing.allocator);
    defer testing.allocator.free(wide_abs);

    // Set every entry to a distinct starting mode so a partial run is visible.
    idx = 0;
    while (idx < count) : (idx += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "wide/f{d}.txt", .{idx});
        const abs = try tmp_dir.dir.realPathFileAlloc(testing.io, name, testing.allocator);
        defer testing.allocator.free(abs);
        try setFileModeOctal(abs, 0o700);
    }

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Target 0o750 keeps the "wide" directory owner-traversable so each entry
    // can be re-stat'd; entries start at 0o700 so the change is detectable.
    const files = [_][]const u8{wide_abs};
    try chmodFiles(
        testing.io,
        testing.allocator,
        "750",
        &files,
        &stdout_aw.writer,
        &stderr_aw.writer,
        ChmodOptions{ .recursive = true },
    );

    // Verify every single entry is now 0o750.
    idx = 0;
    while (idx < count) : (idx += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "wide/f{d}.txt", .{idx});
        const abs = try tmp_dir.dir.realPathFileAlloc(testing.io, name, testing.allocator);
        defer testing.allocator.free(abs);
        try testing.expectEqual(@as(u32, 0o750), try getFileMode(abs));
    }
}
