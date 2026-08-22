//! chown - change file owner and group
const std = @import("std");
const common = @import("common");
const TestDir = common.test_dir.TestDir;
const testing = std.testing;
const fs = std.fs;
const c = std.c;
const privilege_test = common.privilege_test;
const assert = std.debug.assert;

// External C function bindings

/// Changes owner and group of a file (follows symbolic links)
extern "c" fn chown(path: [*:0]const u8, uid: c.uid_t, gid: c.gid_t) c_int;

/// Changes owner and group of a file (does not follow symbolic links)
extern "c" fn lchown(path: [*:0]const u8, uid: c.uid_t, gid: c.gid_t) c_int;

/// Command-line arguments for chown
///
/// Field order is GNU chown's own `longopts[]` order, because that is the
/// order an ambiguous abbreviation lists its candidates in (`chown --v` ->
/// '--verbose' '--version'). Options vibeutils adds that GNU chown has no
/// entry for sit after the GNU sequence.
const ChownArgs = struct {
    /// Operate on files and directories recursively
    recursive: bool = false,
    /// Report only when a change is made
    changes: bool = false,
    /// Affect the referent of symlinks (default, no-op)
    dereference: bool = false,
    /// Affect symbolic links instead of referenced files
    no_dereference: bool = false,
    /// Do not treat '/' specially (default, no-op)
    no_preserve_root: bool = false,
    /// Refuse to operate recursively on '/'
    preserve_root: bool = false,
    /// Same as silent
    quiet: bool = false,
    /// Suppress most error messages
    silent: bool = false,
    /// Use file's owner and group as reference
    reference: ?[]const u8 = null,
    /// Output a diagnostic for every file processed
    verbose: bool = false,
    /// Display help and exit
    help: bool = false,
    /// Display version and exit
    version: bool = false,
    // Not in GNU chown's longopts table.
    /// Traverse symlinks given on the command line
    H: bool = false,
    /// Traverse every symbolic link to a directory encountered
    L: bool = false,
    /// Do not traverse any symbolic links (default behavior)
    P: bool = false,
    /// Numeric IDs only, don't resolve names (macOS)
    numeric_ids: bool = false,
    /// Don't cross mount points during recursion (macOS)
    no_cross_device: bool = false,
    /// Positional arguments (owner spec and file paths)
    positionals: []const []const u8 = &.{},

    /// Metadata for argument parsing
    pub const meta = .{
        // Disable short flag for help.
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .changes = .{
            .short = 'c',
            .desc = "Like verbose but report only when a change is made",
        },
        .silent = .{ .short = 'f', .desc = "Suppress most error messages" },
        .quiet = .{ .desc = "Suppress most error messages" },
        .verbose = .{
            .short = 'v',
            .desc = "Output a diagnostic for every file processed",
        },
        .no_dereference = .{
            .short = 'h',
            .desc = "Affect symbolic links instead of any referenced file",
        },
        .H = .{ .short = 'H', .desc = "Traverse symlinks given on the command line" },
        .L = .{
            .short = 'L',
            .desc = "Traverse every symbolic link to a directory encountered",
        },
        .P = .{ .short = 'P', .desc = "Do not traverse any symbolic links (default)" },
        .recursive = .{ .short = 'R', .desc = "Operate on files and directories recursively" },
        .reference = .{
            .desc = "Use RFILE's owner and group rather than specifying values",
            .value_name = "RFILE",
        },
        .numeric_ids = .{
            .short = 'n',
            .desc = "Use numeric IDs only, do not resolve user/group names",
        },
        .no_cross_device = .{
            .short = 'x',
            .desc = "Don't cross mount points during recursive operations",
        },
        .dereference = .{
            .short = 0,
            .desc = "Affect the referent of each symbolic link (default)",
        },
        .no_preserve_root = .{ .short = 0, .desc = "Do not treat '/' specially (default)" },
        .preserve_root = .{ .short = 0, .desc = "Fail to operate recursively on '/'" },
    };
};

/// Main entry point for chown utility
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runChown);
}

/// Main implementation that accepts writers for output
pub fn runChown(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Parse command-line arguments using the common argument parser
    const parsed_args = common.argparse.ArgParser.parseOrExit(
        ChownArgs,
        allocator,
        args,
        "chown",
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer allocator.free(parsed_args.positionals);

    // Handle information requests (help/version) - these exit immediately
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Get positional arguments for further processing
    const positionals = parsed_args.positionals;

    // Convert arguments to internal options
    const options = runChown_buildOptions(parsed_args);

    // Extract owner spec and file list based on whether --reference is used. A
    // null result means a missing-operand error was already reported; both
    // missing-operand paths map to the same general_error exit code.
    const ops = runChown_extractOperands(
        allocator,
        positionals,
        parsed_args.reference != null,
        stderr_writer,
    ) orelse return @intFromEnum(common.ExitCode.general_error);
    const owner_spec = ops.owner_spec;
    const files = ops.files;

    // Reject --preserve-root on '/' and non-numeric specs under -n. A
    // non-null result is the exit code to return after reporting the error.
    if (runChown_validate(allocator, files, owner_spec, options, stderr_writer)) |code| {
        return code;
    }

    // Parse ownership specification once before the file loop. A null result
    // signals the error was already reported and we should return failure.
    const ownership = (try runChown_resolveOwnership(
        allocator,
        io,
        options,
        owner_spec,
        stderr_writer,
    )) orelse return @intFromEnum(common.ExitCode.general_error);

    // Process each file with pre-parsed ownership
    return runChown_processFiles(
        allocator,
        io,
        files,
        ownership,
        options,
        stdout_writer,
        stderr_writer,
    );
}

/// Owner spec and file list derived from the positional operands.
const Operands = struct {
    owner_spec: []const u8,
    files: []const []const u8,
};

/// Extract the owner spec and file list from the positionals, enforcing the
/// missing-operand guards. With --reference there is no owner spec and at least
/// one file is required; without it the first positional is the owner spec and
/// at least two operands are required. Returns null (after reporting the error)
/// when an operand is missing. Branching stays in the parent, which keeps the
/// reference-vs-spec decision via the reference_is_set primitive.
fn runChown_extractOperands(
    allocator: std.mem.Allocator,
    positionals: []const []const u8,
    reference_is_set: bool,
    stderr_writer: *std.Io.Writer,
) ?Operands {
    if (reference_is_set) {
        // With --reference, we only need files (no owner spec)
        if (positionals.len < 1) {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "chown",
                "missing file operand",
                .{},
            );
            return null;
        }
    } else {
        // Without --reference, we need owner spec + files
        if (positionals.len < 2) {
            common.printErrorWithProgram(allocator, stderr_writer, "chown", "missing operand", .{});
            return null;
        }
    }

    // Past the guards there is always at least one operand to consume.
    assert(positionals.len >= 1);

    const owner_spec: []const u8 = if (reference_is_set) "" else positionals[0];
    const files: []const []const u8 = if (reference_is_set) positionals else positionals[1..];

    // Both extraction branches guarantee at least one file operand: the
    // reference path returns null when positionals.len < 1, the non-reference
    // path when positionals.len < 2 (so positionals[1..] has >= 1 element).
    assert(files.len >= 1);
    // Reference mode and an explicit owner spec are mutually exclusive: the code
    // forces owner_spec = "" whenever --reference is set, so under reference mode
    // the spec is always empty. (`chown "" file` is reference-null and exempt.)
    if (reference_is_set) {
        assert(owner_spec.len == 0);
    }

    return Operands{ .owner_spec = owner_spec, .files = files };
}

/// Build the internal ChownOptions from parsed command-line arguments. Pure
/// field mapping lifted verbatim from runChown to keep the parent under the
/// 70-line cap; -f/--quiet collapse to a single silent flag.
fn runChown_buildOptions(parsed_args: ChownArgs) ChownOptions {
    return ChownOptions{
        .changes = parsed_args.changes,
        .silent = parsed_args.silent or parsed_args.quiet,
        .verbose = parsed_args.verbose,
        .no_dereference = parsed_args.no_dereference,
        .traverse_cmdline_symlinks = parsed_args.H,
        .traverse_all_symlinks = parsed_args.L,
        .no_traverse_symlinks = parsed_args.P,
        .recursive = parsed_args.recursive,
        .reference_file = parsed_args.reference,
        .numeric_ids = parsed_args.numeric_ids,
        .no_cross_device = parsed_args.no_cross_device,
        .preserve_root = parsed_args.preserve_root,
    };
}

/// Validate operands before the file loop: --preserve-root refuses recursive
/// operation on '/', and -n requires a purely numeric owner spec. Returns the
/// exit code to surface (after reporting the error) when validation fails, or
/// null when all checks pass. Branching is centralized here on behalf of the
/// parent so runChown stays under the line cap.
fn runChown_validate(
    allocator: std.mem.Allocator,
    files: []const []const u8,
    owner_spec: []const u8,
    options: ChownOptions,
    stderr_writer: *std.Io.Writer,
) ?u8 {
    // -n only constrains an explicit spec; reference mode leaves owner_spec empty.
    const numeric_applies = options.numeric_ids and owner_spec.len > 0;

    // --preserve-root: refuse to operate recursively on '/'
    if (options.preserve_root and options.recursive) {
        for (files) |file_path| {
            if (std.mem.eql(u8, file_path, "/")) {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "chown",
                    "it is dangerous to operate recursively on '/'\n" ++
                        "Use --no-preserve-root to override this failsafe.",
                    .{},
                );
                return @intFromEnum(common.ExitCode.general_error);
            }
        }
    }

    // -n: validate that owner spec uses only numeric IDs
    if (numeric_applies) {
        if (!isNumericOwnerSpec(owner_spec)) {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "chown",
                "invalid spec: '{s}' (numeric IDs only with -n)",
                .{owner_spec},
            );
            return @intFromEnum(common.ExitCode.general_error);
        }
    }

    return null;
}

/// Resolve the ownership spec once before the file loop, either from a
/// --reference file or by parsing owner_spec. On error it reports via
/// handleError and returns null so the caller returns general_error; on
/// success it returns the parsed OwnershipSpec (warning about octal-mode
/// confusion when applicable).
fn runChown_resolveOwnership(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ChownOptions,
    owner_spec: []const u8,
    stderr_writer: *std.Io.Writer,
) !?common.user_group.OwnershipSpec {
    // Exactly one source supplies ownership: a reference file XOR an owner spec.
    const has_spec = owner_spec.len > 0;
    const has_reference = options.reference_file != null;
    const has_both_sources = has_spec and has_reference;
    // runChown forces owner_spec = "" whenever --reference is set, so a spec and
    // a reference can never both be present (negative space). Note we do NOT
    // assert at-least-one-source: `chown "" file` is valid and yields neither,
    // taking the graceful InvalidFormat path below.
    assert(!has_both_sources);

    var ownership: common.user_group.OwnershipSpec = undefined;
    if (options.reference_file) |ref_path| {
        ownership = getOwnershipFromReference(io, ref_path) catch |err| {
            handleError(allocator, ref_path, err, options, stderr_writer);
            return null;
        };
    } else {
        ownership = common.user_group.OwnershipSpec.parse(owner_spec, allocator) catch |err| {
            handleError(allocator, owner_spec, err, options, stderr_writer);
            return null;
        };
    }

    // Warn if the owner spec looks like an octal permission mode
    if (ownership.warn_octal_confusion) {
        common.printWarningWithProgram(
            allocator,
            stderr_writer,
            "chown",
            "'{s}' looks like a permission mode; did you mean 'chmod {s}'?",
            .{ owner_spec, owner_spec },
        );
    }

    return ownership;
}

/// Apply the pre-parsed ownership to each file, dispatching to the recursive
/// walker or the single-file path per the recursive option. Returns the
/// accumulated exit code (0 on full success, general_error if any file failed).
fn runChown_processFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    files: []const []const u8,
    ownership: common.user_group.OwnershipSpec,
    options: ChownOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) u8 {
    // Precondition mirrored from runChown: the operand-count guards there
    // return general_error before this call when too few positionals are given, so
    // there is always at least one file to process here.
    assert(files.len >= 1);
    // The exit code starts at success and only ever moves to general_error.
    assert(@intFromEnum(common.ExitCode.success) == 0);
    assert(@intFromEnum(common.ExitCode.general_error) != 0);

    var exit_code: u8 = 0;
    for (files) |file_path| {
        if (options.recursive) {
            chownWalk(
                io,
                file_path,
                ownership,
                options,
                allocator,
                stdout_writer,
                stderr_writer,
            ) catch {
                exit_code = @intFromEnum(common.ExitCode.general_error);
            };
        } else {
            chownSingle(
                io,
                allocator,
                file_path,
                ownership,
                options,
                stdout_writer,
                stderr_writer,
            ) catch |err| {
                handleError(allocator, file_path, err, options, stderr_writer);
                exit_code = @intFromEnum(common.ExitCode.general_error);
            };
        }
    }

    // Exit code is either success or general_error, never any other value.
    const is_success = exit_code == 0;
    const is_general_error = exit_code == @intFromEnum(common.ExitCode.general_error);
    const is_known_code = is_success or is_general_error;
    assert(is_known_code);
    return exit_code;
}

/// Print help message
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: chown [OPTION]... [OWNER][:[GROUP]] FILE...
        \\  or:  chown [OPTION]... --reference=RFILE FILE...
        \\Change the owner and/or group of each FILE to OWNER and/or GROUP.
        \\With --reference, change the owner and group of each FILE to those of RFILE.
        \\
        \\  -c, --changes          like verbose but report only when a change is made
        \\  -f, --silent, --quiet  suppress most error messages
        \\  -v, --verbose          output a diagnostic for every file processed
        \\  -h, --no-dereference   affect symbolic links instead of any referenced file
        \\      --dereference       affect the referent of each symbolic link (default)
        \\      --reference=RFILE  use RFILE's owner and group rather than
        \\                         specifying OWNER:GROUP values
        \\  -n                     use numeric IDs only, do not resolve names
        \\  -R, --recursive        operate on files and directories recursively
        \\  -x                     do not cross mount points during recursion
        \\      --preserve-root    fail to operate recursively on '/'
        \\      --no-preserve-root do not treat '/' specially (default)
        \\      --help             display this help and exit
        \\  -V, --version          output version information and exit
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
        \\Owner is unchanged if missing.  Group is unchanged if missing, but changed
        \\to login group if implied by a ':' following a symbolic OWNER.
        \\OWNER and GROUP may be numeric as well as symbolic.
        \\
        \\Examples:
        \\  chown root /u        Change the owner of /u to "root".
        \\  chown root:staff /u  Change the owner of /u to "root" and the group to "staff".
        \\  chown -hR root /u    Change the owner of /u and subfiles to "root".
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("chown ({s}) {s}\n", .{ common.name, common.version });
}

/// Internal options for chown operations
const ChownOptions = struct {
    /// Report only on changes
    changes: bool = false,
    /// Suppress error messages
    silent: bool = false,
    /// Report all operations
    verbose: bool = false,
    /// Don't follow symlinks
    no_dereference: bool = false,
    /// Follow symlinks given on the command line
    traverse_cmdline_symlinks: bool = false,
    /// Follow all symlinks
    traverse_all_symlinks: bool = false,
    /// Never follow symlinks
    no_traverse_symlinks: bool = false,
    /// Change ownership recursively
    recursive: bool = false,
    /// Reference file path
    reference_file: ?[]const u8 = null,
    /// Only accept numeric user/group IDs
    numeric_ids: bool = false,
    /// Don't cross mount points during recursion
    no_cross_device: bool = false,
    /// Refuse to operate recursively on '/'
    preserve_root: bool = false,
};

/// Change ownership of a file or directory
fn chownFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    owner_spec: []const u8,
    options: ChownOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    // Parse ownership specification
    var ownership: common.user_group.OwnershipSpec = undefined;

    if (options.reference_file) |ref_path| {
        // Use reference file's ownership
        ownership = try getOwnershipFromReference(io, ref_path);
    } else {
        // Parse owner specification string
        ownership = try common.user_group.OwnershipSpec.parse(owner_spec, allocator);
    }

    // Apply ownership change
    if (options.recursive) {
        try chownWalk(io, path, ownership, options, allocator, stdout_writer, stderr_writer);
    } else {
        try chownSingle(io, allocator, path, ownership, options, stdout_writer, stderr_writer);
    }
}

/// Change ownership of a single file (non-recursive)
fn chownSingle(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    ownership: common.user_group.OwnershipSpec,
    options: ChownOptions,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    _ = stderr_writer; // Parameter for API consistency, errors bubble up to caller
    // Get current ownership for comparison
    const stat_info = if (options.no_dereference)
        try common.file.FileInfo.lstat(path)
    else
        try common.file.FileInfo.stat(io, path);
    const current_uid = @as(common.user_group.uid_t, @intCast(stat_info.uid));
    const current_gid = @as(common.user_group.gid_t, @intCast(stat_info.gid));

    // Use current values if not specified
    const new_uid = ownership.user orelse current_uid;
    const new_gid = ownership.group orelse current_gid;

    // Check if change is needed
    const changed = (new_uid != current_uid) or (new_gid != current_gid);

    if (changed) {
        // Apply ownership change
        try changeOwnership(allocator, path, new_uid, new_gid, options);

        // Report change if requested
        if (options.verbose or options.changes) {
            try reportChange(stdout_writer, path, current_uid, current_gid, new_uid, new_gid);
        }
    } else if (options.verbose) {
        // Report no change in verbose mode
        try reportNoChange(stdout_writer, path);
    }
}

/// Map chown's -P/-H/-L options to the bounded walker's symlink policy.
/// -L (traverse_all) follows every symlink; -H (traverse_cmdline) follows only
/// the command-line operand; the default (-P or plain -R) follows none.
fn symlinkPolicyFromOptions(options: ChownOptions) common.walker.SymlinkPolicy {
    if (options.traverse_all_symlinks) {
        return .follow_all;
    }
    if (options.traverse_cmdline_symlinks) {
        return .follow_cmdline;
    }
    return .no_follow;
}

/// Change ownership of a tree rooted at `path` using the bounded directory
/// walker. Traversal runs through `common.walker.Walker`, whose explicit,
/// bounded stack avoids self-recursive descent. Post-order (`order = .post`)
/// guarantees each child is chowned before its parent, preserving the prior
/// behavior. Respects -H/-L/-P symlink options and -x mount-point crossing.
fn chownWalk(
    io: std.Io,
    path: []const u8,
    ownership: common.user_group.OwnershipSpec,
    options: ChownOptions,
    allocator: std.mem.Allocator,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    // chownWalk is only ever reached through `if (options.recursive)` dispatch
    // (runChown_processFiles and chownFile), so recursion is code-controlled.
    // Note: path may legitimately be "" (e.g. `chown -R root ""`), so we do NOT
    // assert path.len > 0 here.
    assert(options.recursive);

    const policy = symlinkPolicyFromOptions(options);

    // -P (no_follow): a symlink operand on the command line must be lchown'd
    // as the link itself and NOT descended. GNU/POSIX -P never traverses any
    // symlink, including the operand. lstat the operand and short-circuit when
    // it is a symlink so we never open (and walk into) its target directory.
    if (policy == .no_follow and operandIsSymlink(path)) {
        try chownSingle(io, allocator, path, ownership, options, stdout_writer, stderr_writer);
        return;
    }

    var walk = try common.walker.Walker.init(allocator, .{
        .order = .post,
        .symlinks = policy,
        .stay_on_filesystem = options.no_cross_device,
        // Ancestor-only cycles: a sibling symlink alias of an already-walked
        // directory is chowned again (GNU chown -RL reports both), while an
        // ancestor loop surfaces error.DirectoryCycle so the cycle-forming
        // symlink is serviced as a leaf without re-descending.
        .cycle_mode = .ancestors,
    });
    defer walk.deinit(io);
    try walk.addRoot(path);

    try walkAndApply(
        io,
        &walk,
        path,
        ownership,
        options,
        allocator,
        stdout_writer,
        stderr_writer,
    );
}

/// True when the operand at `path` is itself a symbolic link (lstat, no follow).
/// Used by -P to decide whether to chown the link without descending. A failed
/// lstat returns false so the walker drives normal error reporting downstream.
fn operandIsSymlink(path: []const u8) bool {
    const info = common.file.FileInfo.lstat(path) catch return false;
    return info.kind == .sym_link;
}

/// Outcome of handling one walker.next() error in walkAndApply's drive loop:
/// mirrors the continue/break the loop itself would take for that error class.
const WalkErrorAction = enum { continue_walk, stop_walk };

/// Report (and for DirectoryCycle, service) one walker.next() error for
/// walkAndApply. Extracted from the drive loop's catch arm so walkAndApply
/// stays under the 70-line cap. GNU chown -RL still chowns the cycle-forming
/// symlink itself as a leaf (rc stays 0) rather than descending; cap errors
/// (Depth/EntryLimitExceeded) stop the whole walk, everything else is a
/// per-entry I/O error the walker stays re-entrant after.
fn walkAndApply_handleWalkError(
    io: std.Io,
    walk: *common.walker.Walker,
    path: []const u8,
    err: anyerror,
    ownership: common.user_group.OwnershipSpec,
    options: ChownOptions,
    allocator: std.mem.Allocator,
    stdout_writer: anytype,
    stderr_writer: anytype,
    had_errors: *bool,
) WalkErrorAction {
    assert(options.recursive);
    switch (err) {
        error.DirectoryCycle => {
            chownSingle(
                io,
                allocator,
                walk.cyclePath(),
                ownership,
                options,
                stdout_writer,
                stderr_writer,
            ) catch |e| {
                handleError(allocator, walk.cyclePath(), e, options, stderr_writer);
                had_errors.* = true;
            };
            return .continue_walk;
        },
        error.DepthLimitExceeded, error.EntryLimitExceeded => {
            // EntryLimitExceeded is latched: next() re-returns it forever
            // once the cap is hit (walker.zig:299), so stopping here is
            // mandatory. DepthLimitExceeded is per-entry — the walker
            // consumes the offending dirent and would continue with
            // siblings on the next next() call — so stopping on it is a
            // deliberate abort choice matching chmod/du precedent, not
            // something the walker requires.
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "chown",
                "cannot traverse '{s}': {s}",
                .{ path, common.posixErrorString(err) },
            );
            had_errors.* = true;
            return .stop_walk;
        },
        else => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "chown",
                "cannot traverse '{s}': {s}",
                .{ path, common.posixErrorString(err) },
            );
            had_errors.* = true;
            return .continue_walk;
        },
    }
}

/// Drive the walker to completion, chowning each emitted entry in post-order.
/// Extracted from chownWalk to keep both functions under the 70-line cap and to
/// isolate the bounded drive loop (no recursion). Per-entry failures are
/// reported and tolerated; a walker-level error (e.g. a -L cycle stop) is
/// surfaced as a non-fatal error after the already-emitted output is preserved.
fn walkAndApply(
    io: std.Io,
    walk: *common.walker.Walker,
    path: []const u8,
    ownership: common.user_group.OwnershipSpec,
    options: ChownOptions,
    allocator: std.mem.Allocator,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    assert(options.recursive);
    var had_errors = false;
    // The walker is bounded (max_depth / max_entries) and self-terminating; it
    // returns null when drained, latches terminal cap errors, and stays
    // re-entrant after a per-entry error. Reporting-and-continuing here matches
    // GNU chown, which services every reachable entry rather than aborting on
    // the first failure.
    while (true) { // tiger:allow:unbounded-loop next()->null drains; caps latch+break
        const maybe_entry = walk.next(io) catch |err| {
            switch (walkAndApply_handleWalkError(
                io,
                walk,
                path,
                err,
                ownership,
                options,
                allocator,
                stdout_writer,
                stderr_writer,
                &had_errors,
            )) {
                .continue_walk => continue,
                .stop_walk => break,
            }
        };
        const entry = maybe_entry orelse break;
        chownSingle(
            io,
            allocator,
            entry.path,
            ownership,
            options,
            stdout_writer,
            stderr_writer,
        ) catch |err| {
            handleError(allocator, entry.path, err, options, stderr_writer);
            had_errors = true;
        };
    }

    if (had_errors) {
        return error.FileOperationFailed;
    }
}

/// Perform ownership change via system call
/// Uses chown() or lchown() based on no_dereference option
fn changeOwnership(
    allocator: std.mem.Allocator,
    path: []const u8,
    uid: common.user_group.uid_t,
    gid: common.user_group.gid_t,
    options: ChownOptions,
) !void {
    // Convert path to null-terminated string for system call
    const path_c = try allocator.dupeZ(u8, path);
    defer allocator.free(path_c);

    // Choose between chown and lchown based on no_dereference option
    const result = if (options.no_dereference)
        lchown(path_c.ptr, uid, gid)
    else
        chown(path_c.ptr, uid, gid);

    if (result != 0) {
        // Map errno to appropriate Zig error
        const errno = std.c._errno().*;
        return switch (errno) {
            @intFromEnum(std.c.E.NOENT) => error.FileNotFound,
            @intFromEnum(std.c.E.ACCES) => error.PermissionDenied,
            @intFromEnum(std.c.E.PERM) => error.PermissionDenied,
            @intFromEnum(std.c.E.NOTDIR) => error.NotDir,
            @intFromEnum(std.c.E.LOOP) => error.SymLinkLoop,
            @intFromEnum(std.c.E.NAMETOOLONG) => error.NameTooLong,
            @intFromEnum(std.c.E.ROFS) => error.ReadOnlyFileSystem,
            @intFromEnum(std.c.E.INVAL) => error.InvalidValue,
            @intFromEnum(std.c.E.IO) => error.InputOutputError,
            @intFromEnum(std.c.E.NOMEM) => error.SystemResources,
            else => error.Unexpected,
        };
    }
}

/// Extract ownership from reference file
fn getOwnershipFromReference(io: std.Io, ref_path: []const u8) !common.user_group.OwnershipSpec {
    const stat_info = try common.file.FileInfo.stat(io, ref_path);
    return common.user_group.OwnershipSpec{
        .user = @as(common.user_group.uid_t, @intCast(stat_info.uid)),
        .group = @as(common.user_group.gid_t, @intCast(stat_info.gid)),
    };
}

/// Check if an owner spec is purely numeric (digits and colon only)
/// Used by -n flag to reject name-based specifications
fn isNumericOwnerSpec(spec: []const u8) bool {
    for (spec) |ch| {
        if (ch != ':' and !std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// Report successful ownership change
fn reportChange(
    writer: anytype,
    path: []const u8,
    old_uid: common.user_group.uid_t,
    old_gid: common.user_group.gid_t,
    new_uid: common.user_group.uid_t,
    new_gid: common.user_group.gid_t,
) !void {
    try writer.print(
        "changed ownership of '{s}' from {d}:{d} to {d}:{d}\n",
        .{ path, old_uid, old_gid, new_uid, new_gid },
    );
}

/// Report ownership unchanged
fn reportNoChange(writer: anytype, path: []const u8) !void {
    try writer.print("ownership of '{s}' retained\n", .{path});
}

/// Handle and report errors
fn handleError(
    allocator: std.mem.Allocator,
    path: []const u8,
    err: anyerror,
    options: ChownOptions,
    stderr_writer: anytype,
) void {
    if (options.silent) return; // Suppress errors in silent mode

    // Reporter captures the fixed allocator/writer/program prefix so each switch
    // branch only carries the comptime fmt (required by printErrorWithProgram)
    // and the varying path argument, keeping every branch under the line cap.
    var reporter = errorReporter(allocator, stderr_writer);
    switch (err) {
        error.FileNotFound => reporter.report(
            "cannot access '{s}': No such file or directory",
            .{path},
        ),
        error.PermissionDenied => reporter.report(
            "changing ownership of '{s}': Operation not permitted",
            .{path},
        ),
        error.NotDir => reporter.report("cannot access '{s}': Not a directory", .{path}),
        error.SymLinkLoop => reporter.report(
            "cannot access '{s}': Too many levels of symbolic links",
            .{path},
        ),
        error.NameTooLong => reporter.report("cannot access '{s}': File name too long", .{path}),
        error.ReadOnlyFileSystem => reporter.report(
            "changing ownership of '{s}': Read-only file system",
            .{path},
        ),
        error.InvalidValue => reporter.report("cannot access '{s}': Invalid argument", .{path}),
        error.InputOutputError => reporter.report(
            "cannot access '{s}': Input/output error",
            .{path},
        ),
        error.UserNotFound => reporter.report("invalid user", .{}),
        error.GroupNotFound => reporter.report("invalid group", .{}),
        error.InvalidFormat => reporter.report("invalid owner specification", .{}),
        error.SystemResources => reporter.report(
            "cannot access '{s}': Cannot allocate memory",
            .{path},
        ),
        error.Unexpected => reporter.report("cannot access '{s}': Unexpected error", .{path}),
        else => reporter.report(
            "cannot access '{s}': {s}",
            .{ path, common.posixErrorString(err) },
        ),
    }
}

/// Build an ErrorReporter generic over the concrete writer type so handleError
/// keeps accepting `anytype` writers without narrowing their type.
fn errorReporter(allocator: std.mem.Allocator, writer: anytype) ErrorReporter(@TypeOf(writer)) {
    return .{ .allocator = allocator, .writer = writer };
}

/// Captures the fixed allocator/writer/program-name prefix shared by every
/// chown diagnostic so handleError's switch branches stay short.
fn ErrorReporter(comptime Writer: type) type {
    return struct {
        allocator: std.mem.Allocator,
        writer: Writer,

        fn report(self: *@This(), comptime fmt: []const u8, args: anytype) void {
            common.printErrorWithProgram(self.allocator, self.writer, "chown", fmt, args);
        }
    };
}

// Tests

// Regular tests run without privileges
// Privileged tests require fakeroot and are named with "privileged:" prefix

test "privileged: chown basic functionality" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            // Create a test file
            const file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
            file.close(testing.io);

            // Get real path for the temporary directory
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            // Get current user for the test
            const current_uid = common.user_group.getCurrentUserId();
            const current_gid = common.user_group.getCurrentGroupId();

            const owner_spec = try std.fmt.allocPrint(
                inner_allocator,
                "{d}:{d}",
                .{ current_uid, current_gid },
            );

            const options = ChownOptions{};

            // This should work for changing to the same ownership
            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();
            try chownFile(
                testing.io,
                inner_allocator,
                test_file,
                owner_spec,
                options,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );
        }
    }.testFn);
}

test "chown with invalid owner specification" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    file.close(testing.io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/test.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const options = ChownOptions{};

    // Empty specification should fail
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    try testing.expectError(error.InvalidFormat, chownFile(
        testing.io,
        testing.allocator,
        test_file,
        "",
        options,
        &stdout_aw.writer,
        &stderr_aw.writer,
    ));
}

test "privileged: chown user only specification" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            const file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
            file.close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}", .{current_uid});

            const options = ChownOptions{};

            // Should work for user-only specification
            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();
            try chownFile(
                testing.io,
                inner_allocator,
                test_file,
                owner_spec,
                options,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );
        }
    }.testFn);
}

test "privileged: chown group only specification" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            const file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
            file.close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            const current_gid = common.user_group.getCurrentGroupId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, ":{d}", .{current_gid});

            const options = ChownOptions{};

            // Should work for group-only specification
            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();
            try chownFile(
                testing.io,
                inner_allocator,
                test_file,
                owner_spec,
                options,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );
        }
    }.testFn);
}

test "privileged: chown with reference file" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            // Create reference and target files
            const ref_file = try tmp_dir.dir().createFile(testing.io, "reference.txt", .{});
            ref_file.close(testing.io);

            const target_file = try tmp_dir.dir().createFile(testing.io, "target.txt", .{});
            target_file.close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const ref_path = try std.fmt.allocPrint(
                inner_allocator,
                "{s}/reference.txt",
                .{tmp_path},
            );

            const target_path = try std.fmt.allocPrint(
                inner_allocator,
                "{s}/target.txt",
                .{tmp_path},
            );

            const options = ChownOptions{ .reference_file = ref_path };

            // Should use reference file's ownership
            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();
            try chownFile(
                testing.io,
                inner_allocator,
                target_path,
                "",
                options,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );
        }
    }.testFn);
}

test "chown nonexistent file" {
    const options = ChownOptions{};
    const current_uid = common.user_group.getCurrentUserId();
    const owner_spec = try std.fmt.allocPrint(testing.allocator, "{d}", .{current_uid});
    defer testing.allocator.free(owner_spec);

    // Should fail for nonexistent file
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    try testing.expectError(error.FileNotFound, chownFile(
        testing.io,
        testing.allocator,
        "/nonexistent/file",
        owner_spec,
        options,
        &stdout_aw.writer,
        &stderr_aw.writer,
    ));
}

test "OwnershipSpec parsing" {
    // Test various ownership specification formats
    const spec1 = try common.user_group.OwnershipSpec.parse("1000:100", testing.allocator);
    try testing.expectEqual(@as(common.user_group.uid_t, 1000), spec1.user.?);
    try testing.expectEqual(@as(common.user_group.gid_t, 100), spec1.group.?);

    const spec2 = try common.user_group.OwnershipSpec.parse("1000", testing.allocator);
    try testing.expectEqual(@as(common.user_group.uid_t, 1000), spec2.user.?);
    try testing.expectEqual(@as(?common.user_group.gid_t, null), spec2.group);

    const spec3 = try common.user_group.OwnershipSpec.parse(":100", testing.allocator);
    try testing.expectEqual(@as(?common.user_group.uid_t, null), spec3.user);
    try testing.expectEqual(@as(common.user_group.gid_t, 100), spec3.group.?);
}

test "getOwnershipFromReference" {
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const file = try tmp_dir.dir().createFile(testing.io, "ref.txt", .{});
    file.close(testing.io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/ref.txt", .{tmp_path});
    defer testing.allocator.free(ref_path);

    const ownership = try getOwnershipFromReference(testing.io, ref_path);
    try testing.expect(ownership.user != null);
    try testing.expect(ownership.group != null);
}

test "privileged: changeOwnership with same values" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            const file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
            file.close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            // Get current ownership
            const stat_info = try common.file.FileInfo.stat(testing.io, test_file);
            const current_uid = @as(common.user_group.uid_t, @intCast(stat_info.uid));
            const current_gid = @as(common.user_group.gid_t, @intCast(stat_info.gid));

            const options = ChownOptions{};

            // Should succeed when changing to same ownership
            try changeOwnership(inner_allocator, test_file, current_uid, current_gid, options);
        }
    }.testFn);
}

test "privileged: chownSingle basic operation" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            const file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
            file.close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            // Get current ownership
            const stat_info = try common.file.FileInfo.stat(testing.io, test_file);
            const current_uid = @as(common.user_group.uid_t, @intCast(stat_info.uid));
            const current_gid = @as(common.user_group.gid_t, @intCast(stat_info.gid));

            const ownership = common.user_group.OwnershipSpec{
                .user = current_uid,
                .group = current_gid,
            };

            const options = ChownOptions{};

            // Should work for same ownership
            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();
            try chownSingle(
                testing.io,
                inner_allocator,
                test_file,
                ownership,
                options,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );
        }
    }.testFn);
}

test "privileged: chown recursive option" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            // Create a directory structure
            try tmp_dir.dir().createDir(testing.io, "testdir", .default_dir);
            var subdir = try tmp_dir.dir().openDir(testing.io, "testdir", .{});
            defer subdir.close(testing.io);
            const file = try subdir.createFile(testing.io, "file.txt", .{});
            file.close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const test_dir = try std.fmt.allocPrint(inner_allocator, "{s}/testdir", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const current_gid = common.user_group.getCurrentGroupId();
            const owner_spec = try std.fmt.allocPrint(
                inner_allocator,
                "{d}:{d}",
                .{ current_uid, current_gid },
            );

            const options = ChownOptions{ .recursive = true };

            // Should work recursively
            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();
            try chownFile(
                testing.io,
                inner_allocator,
                test_dir,
                owner_spec,
                options,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );
        }
    }.testFn);
}

test "privileged: chown with verbose option" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            const file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
            file.close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}", .{current_uid});

            const options = ChownOptions{ .verbose = true };

            // Should work with verbose output
            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();
            try chownFile(
                testing.io,
                inner_allocator,
                test_file,
                owner_spec,
                options,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );
        }
    }.testFn);
}

test "privileged: chown with changes option" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            const file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
            file.close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}", .{current_uid});

            const options = ChownOptions{ .changes = true };

            // Should work with changes option
            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();
            try chownFile(
                testing.io,
                inner_allocator,
                test_file,
                owner_spec,
                options,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );
        }
    }.testFn);
}

test "privileged: chown with no-dereference option" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            // Create a file and a symlink to it
            const file = try tmp_dir.dir().createFile(testing.io, "target.txt", .{});
            file.close(testing.io);

            // Create symlink (this might fail on some systems)
            tmp_dir.dir().symLink(testing.io, "target.txt", "link.txt", .{}) catch {
                return;
            };

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const test_link = try std.fmt.allocPrint(inner_allocator, "{s}/link.txt", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}", .{current_uid});

            const options = ChownOptions{ .no_dereference = true };

            // Should work with no-dereference option
            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();
            try chownFile(
                testing.io,
                inner_allocator,
                test_link,
                owner_spec,
                options,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );
        }
    }.testFn);
}

test "chown with silent option suppresses errors" {
    const current_uid = common.user_group.getCurrentUserId();
    const owner_spec = try std.fmt.allocPrint(testing.allocator, "{d}", .{current_uid});
    defer testing.allocator.free(owner_spec);

    const options = ChownOptions{ .silent = true };

    // Should not panic or output errors for nonexistent file in silent mode
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const result = chownFile(
        testing.io,
        testing.allocator,
        "/nonexistent/path",
        owner_spec,
        options,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectError(error.FileNotFound, result);
}

test "privileged: chown traverse options" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege(testing.io);

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            const file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
            file.close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}", .{current_uid});

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            // Test traverse all symlinks
            const options_l = ChownOptions{ .traverse_all_symlinks = true };
            try chownFile(
                testing.io,
                inner_allocator,
                test_file,
                owner_spec,
                options_l,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );

            // Test no traverse symlinks (default)
            const options_p = ChownOptions{ .no_traverse_symlinks = true };
            try chownFile(
                testing.io,
                inner_allocator,
                test_file,
                owner_spec,
                options_p,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );
        }
    }.testFn);
}

test "error handling different error types" {
    const options = ChownOptions{};

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test invalid owner specification
    const result1 = chownFile(
        testing.io,
        testing.allocator,
        "/nonexistent/test",
        "",
        options,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectError(error.InvalidFormat, result1);

    // Test nonexistent file (with valid owner spec)
    const current_uid = common.user_group.getCurrentUserId();
    const owner_spec = try std.fmt.allocPrint(testing.allocator, "{d}", .{current_uid});
    defer testing.allocator.free(owner_spec);

    const result2 = chownFile(
        testing.io,
        testing.allocator,
        "/nonexistent/file",
        owner_spec,
        options,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );
    try testing.expectError(error.FileNotFound, result2);
}

test "reportChange function" {
    // The reportChange and reportNoChange functions now accept writer: anytype
    // and return !void. This is verified by compilation.
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // Test that the functions can be called without error
    try reportChange(&stdout_aw.writer, "/test", 1000, 100, 1001, 101);
    try reportNoChange(&stdout_aw.writer, "/test");

    // Verify output was written
    try testing.expect(stdout_aw.writer.buffered().len > 0);
}

test "chown printHelp does not crash" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    try printHelp(testing.allocator, &stdout_aw.writer);

    // Verify help output contains key content
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: chown") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "OWNER") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--recursive") != null);
}

test "chown --help flag works via runChown" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const exit_code = try runChown(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: chown") != null);
}

test "chown --version flag works" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--version"};
    const exit_code = try runChown(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "chown") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), common.version) != null);
}

// Tests for new flags

test "isNumericOwnerSpec accepts numeric specs" {
    try testing.expect(isNumericOwnerSpec("1000"));
    try testing.expect(isNumericOwnerSpec("1000:100"));
    try testing.expect(isNumericOwnerSpec(":100"));
    try testing.expect(isNumericOwnerSpec("0:0"));
}

test "isNumericOwnerSpec rejects name specs" {
    try testing.expect(!isNumericOwnerSpec("root"));
    try testing.expect(!isNumericOwnerSpec("root:staff"));
    try testing.expect(!isNumericOwnerSpec(":staff"));
    try testing.expect(!isNumericOwnerSpec("root:100"));
}

test "chown -n flag rejects non-numeric owner spec" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-n", "root", "/tmp/test" };
    const exit_code = try runChown(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "numeric IDs only") != null);
}

test "chown -n flag accepts numeric owner spec" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Uses a nonexistent file, but the -n validation should pass
    const args = [_][]const u8{ "-n", "1000:100", "/nonexistent/test" };
    const exit_code = try runChown(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Should fail due to nonexistent file, not due to -n validation. Argument
    // errors and operational errors now share exit code 1, so the code alone
    // cannot tell them apart; pin the diagnostic instead.
    try testing.expect(exit_code != 0);
    try testing.expect(std.mem.find(
        u8,
        stderr_aw.writer.buffered(),
        "numeric IDs only",
    ) == null);
}

test "chown --preserve-root blocks recursive on /" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--preserve-root", "-R", "1000:1000", "/" };
    const exit_code = try runChown(
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

test "chown --preserve-root allows non-recursive on /" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Without -R, --preserve-root should not block
    const args = [_][]const u8{ "--preserve-root", "1000:1000", "/" };
    const exit_code = try runChown(
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

test "chown --dereference flag is accepted" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--dereference", "--help" };
    const exit_code = try runChown(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "chown --no-preserve-root flag is accepted" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "--no-preserve-root", "--help" };
    const exit_code = try runChown(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "chown -x flag is accepted" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-x", "--help" };
    const exit_code = try runChown(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "runChown production path with valid file and owner spec" {
    // Safety net: exercises the full production path (runChown -> chownSingle)
    // using the file's current uid:gid so no actual ownership change occurs.
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const file = try tmp_dir.dir().createFile(testing.io, "test.txt", .{});
    file.close(testing.io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];
    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/test.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    // Get current ownership so the spec matches (no actual change)
    const stat_info = try common.file.FileInfo.stat(testing.io, test_file);
    const owner_spec = try std.fmt.allocPrint(testing.allocator, "{d}:{d}", .{
        @as(common.user_group.uid_t, @intCast(stat_info.uid)),
        @as(common.user_group.gid_t, @intCast(stat_info.gid)),
    });
    defer testing.allocator.free(owner_spec);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ owner_spec, test_file };
    const exit_code = try runChown(
        testing.allocator,
        testing.io,
        &args,
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
}

test "privileged: chown -RP should not follow cmdline symlink to directory" {
    // GNU/POSIX: -P means "Do not traverse any symbolic links."
    // When a symlink-to-directory is passed on the command line with -RP,
    // chown should change the symlink itself, NOT recurse into the target.
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            // Create target directory with a file inside
            try tmp_dir.dir().createDir(testing.io, "target", .default_dir);
            var subdir = try tmp_dir.dir().openDir(testing.io, "target", .{});
            defer subdir.close(testing.io);
            const file = try subdir.createFile(testing.io, "file.txt", .{});
            file.close(testing.io);

            // Create a symlink to the target directory
            try tmp_dir.dir().symLink(testing.io, "target", "link", .{});

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const tmp_path_len = try tmp_dir.dir().realPathFile(testing.io, ".", &path_buf);
            const tmp_path = path_buf[0..tmp_path_len];

            const link_path = try std.fmt.allocPrint(inner_allocator, "{s}/link", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const current_gid = common.user_group.getCurrentGroupId();
            const owner_spec = try std.fmt.allocPrint(
                inner_allocator,
                "{d}:{d}",
                .{ current_uid, current_gid },
            );

            // -R with -P (no_traverse_symlinks): should NOT follow the symlink
            const options = ChownOptions{
                .recursive = true,
                .no_traverse_symlinks = true,
                .verbose = true,
            };

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            try chownFile(
                testing.io,
                inner_allocator,
                link_path,
                owner_spec,
                options,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );

            // Verbose output should only mention "link", not "target/file.txt"
            const output = stdout_aw.writer.buffered();
            try testing.expect(std.mem.find(u8, output, "file.txt") == null);
        }
    }.testFn);
}

test "chown help text includes new flags" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    try printHelp(testing.allocator, &stdout_aw.writer);

    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--preserve-root") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--no-preserve-root") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--dereference") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "numeric IDs") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "mount points") != null);
}

// Characterization tests for the recursion -> bounded-walker migration.
//
// These tests lock in the OBSERVABLE behavior that the walker rewrite must
// preserve. They PASS on the current recursive implementation; their job is
// to go RED if a future walker-based rewrite changes traversal coverage,
// ordering, symlink policy, cross-device pruning, or robustness. Because the
// verbose stream prints the exact path of every entry chowned, asserting which
// paths appear (and which do NOT) directly characterizes traversal coverage,
// ordering, and symlink/device policy without needing real ownership changes.
//
// All recursive-walk tests are privileged: they run under fakeroot so that
// chownSingle's chown/lchown syscalls succeed and the verbose lines are
// emitted. A non-privileged run skips via requiresPrivilege.

const characterization_uid: common.user_group.uid_t = 4242;
const characterization_gid: common.user_group.gid_t = 4243;

/// Resolve the realpath of a test tmp dir into the caller-provided buffer and
/// return a slice owned by inner_allocator (stable for the test's lifetime).
fn characterizationTmpRealpath(
    inner_allocator: std.mem.Allocator,
    tmp_dir: *TestDir,
    path_buf: *[std.Io.Dir.max_path_bytes]u8,
) ![]const u8 {
    const len = try tmp_dir.dir().realPathFile(testing.io, ".", path_buf);
    return inner_allocator.dupe(u8, path_buf[0..len]);
}

/// True when the verbose stream reported a change for the given quoted path.
/// The verbose line format is: changed ownership of '<path>' from ... to ...
/// so a fully-quoted marker like "'/abs/path'" cannot false-match a longer
/// path that merely shares a prefix.
fn characterizationReported(output: []const u8, quoted_path: []const u8) bool {
    return std.mem.find(u8, output, quoted_path) != null;
}

/// Build a fully-quoted verbose marker '<base><suffix>' for the given path
/// suffix. Equivalent to allocPrint("'{s}{s}'", .{ base, suffix }); extracted so
/// the marker-heavy characterization tests stay under the per-function line cap.
fn characterizationMarker(
    inner_allocator: std.mem.Allocator,
    base: []const u8,
    suffix: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(inner_allocator, "'{s}{s}'", .{ base, suffix });
}

test "privileged: recursive walk reports a change for every entry in a multi-level tree" {
    // Guards full coverage: -R must chown EVERY entry in the tree, not
    // just the root. The walker rewrite must reproduce full coverage. A
    // regression that stops descending (or skips leaves) drops one of the
    // asserted markers and the test goes RED.
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            // root/{child.txt, subdir/{grandchild.txt}}
            try tmp_dir.dir().createDir(testing.io, "root", .default_dir);
            var root = try tmp_dir.dir().openDir(testing.io, "root", .{});
            defer root.close(testing.io);
            (try root.createFile(testing.io, "child.txt", .{})).close(testing.io);
            try root.createDir(testing.io, "subdir", .default_dir);
            var subdir = try root.openDir(testing.io, "subdir", .{});
            defer subdir.close(testing.io);
            (try subdir.createFile(testing.io, "grandchild.txt", .{})).close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const base = try characterizationTmpRealpath(inner_allocator, &tmp_dir, &path_buf);
            const root_path = try std.fmt.allocPrint(inner_allocator, "{s}/root", .{base});

            const ownership = common.user_group.OwnershipSpec{
                .user = characterization_uid,
                .group = characterization_gid,
            };
            const options = ChownOptions{ .recursive = true, .verbose = true };

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            try chownWalk(
                testing.io,
                root_path,
                ownership,
                options,
                inner_allocator,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );

            const out = stdout_aw.writer.buffered();
            // Every entry in the tree must be reported.
            const expected = [_][]const u8{
                "'{s}/root'",
                "'{s}/root/child.txt'",
                "'{s}/root/subdir'",
                "'{s}/root/subdir/grandchild.txt'",
            };
            inline for (expected) |fmt| {
                const quoted = try std.fmt.allocPrint(inner_allocator, fmt, .{base});
                try testing.expect(characterizationReported(out, quoted));
            }
        }
    }.testFn);
}

test "privileged: recursive walk processes children before their parent directory (post-order)" {
    // Guards post-order: each directory's own verbose line must appear AFTER
    // every line for its children. The walker rewrite uses order=.post and
    // must keep this; a pre-order regression would emit the parent first and
    // flip the position checks below to RED.
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            try tmp_dir.dir().createDir(testing.io, "root", .default_dir);
            var root = try tmp_dir.dir().openDir(testing.io, "root", .{});
            defer root.close(testing.io);
            (try root.createFile(testing.io, "child.txt", .{})).close(testing.io);
            try root.createDir(testing.io, "subdir", .default_dir);
            var subdir = try root.openDir(testing.io, "subdir", .{});
            defer subdir.close(testing.io);
            (try subdir.createFile(testing.io, "grandchild.txt", .{})).close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const base = try characterizationTmpRealpath(inner_allocator, &tmp_dir, &path_buf);
            const root_path = try std.fmt.allocPrint(inner_allocator, "{s}/root", .{base});

            const ownership = common.user_group.OwnershipSpec{
                .user = characterization_uid,
                .group = characterization_gid,
            };
            const options = ChownOptions{ .recursive = true, .verbose = true };

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            try chownWalk(
                testing.io,
                root_path,
                ownership,
                options,
                inner_allocator,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );

            const out = stdout_aw.writer.buffered();

            const grandchild_marker =
                try characterizationMarker(inner_allocator, base, "/root/subdir/grandchild.txt");
            const child_marker =
                try characterizationMarker(inner_allocator, base, "/root/child.txt");
            const subdir_marker = try characterizationMarker(inner_allocator, base, "/root/subdir");
            const root_marker = try characterizationMarker(inner_allocator, base, "/root");

            const grandchild_pos = std.mem.find(u8, out, grandchild_marker) orelse
                return error.MissingGrandchildLine;
            const child_pos = std.mem.find(u8, out, child_marker) orelse
                return error.MissingChildLine;
            // The subdir and root markers are prefixes of their children's
            // paths, so search for the LAST occurrence: the directory's own
            // trailing quote in the marker makes each match the directory's own
            // line, which (under post-order) comes after its children.
            const subdir_pos = std.mem.lastIndexOf(u8, out, subdir_marker) orelse
                return error.MissingSubdirLine;
            const root_pos = std.mem.lastIndexOf(u8, out, root_marker) orelse
                return error.MissingRootLine;

            // grandchild before its parent subdir; subdir before root.
            try testing.expect(grandchild_pos < subdir_pos);
            try testing.expect(child_pos < root_pos);
            try testing.expect(subdir_pos < root_pos);
        }
    }.testFn);
}

test "privileged: -P reports the symlink itself and does not descend into its target" {
    // Guards: under no_traverse_symlinks (-P), a symlink encountered during
    // recursion is processed in place (lchown on the LINK) and its target
    // subtree is NOT traversed. The walker rewrite emits such symlinks as
    // .sym_link with no descent. We assert the link IS reported while the file
    // behind it is NOT.
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            // outside/secret.txt is the symlink target; must stay untouched.
            try tmp_dir.dir().createDir(testing.io, "outside", .default_dir);
            var outside = try tmp_dir.dir().openDir(testing.io, "outside", .{});
            defer outside.close(testing.io);
            (try outside.createFile(testing.io, "secret.txt", .{})).close(testing.io);

            try tmp_dir.dir().createDir(testing.io, "root", .default_dir);
            var root = try tmp_dir.dir().openDir(testing.io, "root", .{});
            defer root.close(testing.io);
            root.symLink(testing.io, "../outside", "link", .{}) catch return error.SkipZigTest;

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const base = try characterizationTmpRealpath(inner_allocator, &tmp_dir, &path_buf);
            const root_path = try std.fmt.allocPrint(inner_allocator, "{s}/root", .{base});

            const ownership = common.user_group.OwnershipSpec{
                .user = characterization_uid,
                .group = characterization_gid,
            };
            // -P with -h so the link node itself is lchown'd and reported.
            const options = ChownOptions{
                .recursive = true,
                .no_traverse_symlinks = true,
                .no_dereference = true,
                .verbose = true,
            };

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            try chownWalk(
                testing.io,
                root_path,
                ownership,
                options,
                inner_allocator,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );

            const out = stdout_aw.writer.buffered();

            const link_marker = try std.fmt.allocPrint(inner_allocator, "'{s}/root/link'", .{base});
            // If -P regressed and DID descend, the leaked file would be
            // reported THROUGH the link name (paths are built by joining the
            // traversal path with the entry name, never via the real target),
            // exactly like the -L test reports "'{base}/root/link/reached.txt'".
            // So the through-link form is the only marker that can actually
            // surface a descent regression.
            const secret_marker = try std.fmt.allocPrint(
                inner_allocator,
                "'{s}/root/link/secret.txt'",
                .{base},
            );

            // The link itself must be reported.
            try testing.expect(characterizationReported(out, link_marker));
            // The target subtree must NOT be entered (no descent through -P).
            try testing.expect(!characterizationReported(out, secret_marker));
        }
    }.testFn);
}

test "privileged: -L follows a symlink-to-directory and reports the target subtree" {
    // Guards: under traverse_all_symlinks (-L), a symlink to a directory is
    // followed and entries beneath the target ARE processed. The walker
    // rewrite maps -L to .follow_all and must descend through the link. We
    // assert the file behind the link is reported.
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            try tmp_dir.dir().createDir(testing.io, "outside", .default_dir);
            var outside = try tmp_dir.dir().openDir(testing.io, "outside", .{});
            defer outside.close(testing.io);
            (try outside.createFile(testing.io, "reached.txt", .{})).close(testing.io);

            try tmp_dir.dir().createDir(testing.io, "root", .default_dir);
            var root = try tmp_dir.dir().openDir(testing.io, "root", .{});
            defer root.close(testing.io);
            root.symLink(testing.io, "../outside", "link", .{}) catch return error.SkipZigTest;

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const base = try characterizationTmpRealpath(inner_allocator, &tmp_dir, &path_buf);
            const root_path = try std.fmt.allocPrint(inner_allocator, "{s}/root", .{base});

            const ownership = common.user_group.OwnershipSpec{
                .user = characterization_uid,
                .group = characterization_gid,
            };
            const options = ChownOptions{
                .recursive = true,
                .traverse_all_symlinks = true,
                .verbose = true,
            };

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            try chownWalk(
                testing.io,
                root_path,
                ownership,
                options,
                inner_allocator,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );

            const out = stdout_aw.writer.buffered();
            // Following the link reaches the file behind it via the link path.
            // Anchor on the full quoted path (leading quote + base) so the
            // marker cannot false-match any other reported path.
            const reached_marker = try std.fmt.allocPrint(
                inner_allocator,
                "'{s}/root/link/reached.txt'",
                .{base},
            );
            try testing.expect(characterizationReported(out, reached_marker));
        }
    }.testFn);
}

/// Build the -H fixture: operand_target/{via_operand.txt, nested_link ->
/// ../nested_target}, nested_target/via_nested.txt, and operand_link ->
/// operand_target. Returns the absolute path of the operand symlink. Extracted
/// from the -H characterization test so its testFn stays under the line cap;
/// the on-disk layout and names are unchanged. Symlink-creation failures map to
/// error.SkipZigTest exactly as the inline version did.
fn setupCmdlineSymlinkFixture(
    inner_allocator: std.mem.Allocator,
    tmp_dir: *TestDir,
) ![]const u8 {
    // operand_target/ holds entries reachable only by FOLLOWING the
    // command-line symlink. nested_target/ holds an entry reachable
    // only by following a symlink found DURING recursion.
    try tmp_dir.dir().createDir(testing.io, "operand_target", .default_dir);
    var operand_target = try tmp_dir.dir().openDir(testing.io, "operand_target", .{});
    defer operand_target.close(testing.io);
    (try operand_target.createFile(testing.io, "via_operand.txt", .{})).close(testing.io);

    // A nested symlink inside operand_target pointing at nested_target.
    try tmp_dir.dir().createDir(testing.io, "nested_target", .default_dir);
    var nested_target = try tmp_dir.dir().openDir(testing.io, "nested_target", .{});
    defer nested_target.close(testing.io);
    (try nested_target.createFile(testing.io, "via_nested.txt", .{})).close(testing.io);
    operand_target.symLink(testing.io, "../nested_target", "nested_link", .{}) catch
        return error.SkipZigTest;

    // The command-line operand is itself a symlink to operand_target.
    tmp_dir.dir().symLink(testing.io, "operand_target", "operand_link", .{}) catch
        return error.SkipZigTest;

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try characterizationTmpRealpath(inner_allocator, tmp_dir, &path_buf);
    // Pass the SYMLINK as the operand so depth-0 following is exercised.
    return std.fmt.allocPrint(inner_allocator, "{s}/operand_link", .{base});
}

test "privileged: -H follows a command-line symlink but not symlinks found during recursion" {
    // Guards: under traverse_cmdline_symlinks (-H) the symlink policy is
    // depth-sensitive. A symlink-to-directory passed AS the operand (depth 0)
    // must be followed and its target subtree processed; a symlink-to-directory
    // encountered DURING recursion (depth > 0) must NOT be descended (it is
    // chowned in place, like -P). This is the distinguishing fixture for -H:
    // the walker rewrite maps -H to the .follow_cmdline policy, and a wrong
    // mapping that collapsed -H into -P (operand link not followed) or into -L
    // (nested link followed) would fail exactly one of the two assertions here.
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            // Pass the SYMLINK as the operand so depth-0 following is exercised.
            const operand_path = try setupCmdlineSymlinkFixture(inner_allocator, &tmp_dir);

            const ownership = common.user_group.OwnershipSpec{
                .user = characterization_uid,
                .group = characterization_gid,
            };
            const options = ChownOptions{
                .recursive = true,
                .traverse_cmdline_symlinks = true,
                .verbose = true,
            };

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            try chownWalk(
                testing.io,
                operand_path,
                ownership,
                options,
                inner_allocator,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );

            const out = stdout_aw.writer.buffered();

            // The command-line symlink WAS followed: the file behind it, reached
            // through the operand path, must be reported. operand_path is
            // '<base>/operand_link', so the marker equals the original
            // "'{s}/operand_link/via_operand.txt'" built from base.
            const via_operand_marker =
                try characterizationMarker(inner_allocator, operand_path, "/via_operand.txt");
            try testing.expect(characterizationReported(out, via_operand_marker));

            // The nested symlink found during recursion was NOT descended: the
            // file behind it must NOT be reported. Paths are built through the
            // traversal/link name, so a wrongly-descended nested link would
            // surface as '.../operand_link/nested_link/via_nested.txt'; the
            // through-link substring below has teeth against that regression.
            const via_nested_through_operand = try std.fmt.allocPrint(
                inner_allocator,
                "/nested_link/via_nested.txt'",
                .{},
            );
            try testing.expect(!characterizationReported(out, via_nested_through_operand));
        }
    }.testFn);
}

test "privileged: -x stays on the same filesystem and still reports same-device entries" {
    // Guards: with no_cross_device (-x), the walker's stay_on_filesystem device
    // tracking continues descent across entries that share that device. A wrong
    // device comparison could prune everything; this test ensures same-device
    // children are still fully processed. Cross-device pruning itself needs a
    // real mount and is covered by integration tests; here we lock in that -x
    // does not break the common single-filesystem case.
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            try tmp_dir.dir().createDir(testing.io, "root", .default_dir);
            var root = try tmp_dir.dir().openDir(testing.io, "root", .{});
            defer root.close(testing.io);
            try root.createDir(testing.io, "sub", .default_dir);
            var sub = try root.openDir(testing.io, "sub", .{});
            defer sub.close(testing.io);
            (try sub.createFile(testing.io, "leaf.txt", .{})).close(testing.io);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const base = try characterizationTmpRealpath(inner_allocator, &tmp_dir, &path_buf);
            const root_path = try std.fmt.allocPrint(inner_allocator, "{s}/root", .{base});

            const ownership = common.user_group.OwnershipSpec{
                .user = characterization_uid,
                .group = characterization_gid,
            };
            const options = ChownOptions{
                .recursive = true,
                .no_cross_device = true,
                .verbose = true,
            };

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            try chownWalk(
                testing.io,
                root_path,
                ownership,
                options,
                inner_allocator,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );

            const out = stdout_aw.writer.buffered();
            // The deep same-device leaf must still be reached under -x.
            const leaf_marker = try std.fmt.allocPrint(
                inner_allocator,
                "'{s}/root/sub/leaf.txt'",
                .{base},
            );
            try testing.expect(characterizationReported(out, leaf_marker));
        }
    }.testFn);
}

test "privileged: deep directory tree completes without stack overflow" {
    // Guards robustness: a deep tree must complete. The leaf being reported
    // can only happen if traversal reached the bottom without overflowing.
    // The current recursion handles this depth; the walker rewrite (explicit
    // stack, max_depth=1024) must too. Depth 100 is well under that bound and
    // far past where unbounded recursion risk would matter for the assertion.
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            try tmp_dir.dir().createDir(testing.io, "root", .default_dir);

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const base = try characterizationTmpRealpath(inner_allocator, &tmp_dir, &path_buf);
            const root_path = try std.fmt.allocPrint(inner_allocator, "{s}/root", .{base});

            // Build root/d/d/d/.../leaf.txt at depth 100.
            const depth: usize = 100;
            var leaf_path: std.array_list.Managed(u8) = .init(inner_allocator);
            defer leaf_path.deinit();
            try leaf_path.appendSlice("'");
            try leaf_path.appendSlice(root_path);

            var current = try std.Io.Dir.cwd().openDir(testing.io, root_path, .{});
            var i: usize = 0;
            while (i < depth) : (i += 1) {
                try current.createDir(testing.io, "d", .default_dir);
                const next = try current.openDir(testing.io, "d", .{});
                current.close(testing.io);
                current = next;
                try leaf_path.appendSlice("/d");
            }
            (try current.createFile(testing.io, "leaf.txt", .{})).close(testing.io);
            current.close(testing.io);
            try leaf_path.appendSlice("/leaf.txt'");

            const ownership = common.user_group.OwnershipSpec{
                .user = characterization_uid,
                .group = characterization_gid,
            };
            const options = ChownOptions{ .recursive = true, .verbose = true };

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            try chownWalk(
                testing.io,
                root_path,
                ownership,
                options,
                inner_allocator,
                &stdout_aw.writer,
                &stderr_aw.writer,
            );

            const out = stdout_aw.writer.buffered();
            // Reaching the deepest leaf proves the traversal ran to the bottom.
            try testing.expect(characterizationReported(out, leaf_path.items));
        }
    }.testFn);
}

test "privileged: -L with a symlink cycle terminates cleanly instead of looping forever" {
    // Guards robustness: under -L a symlink cycle must not loop forever. The
    // current recursion relies on the kernel's ELOOP; the walker rewrite
    // relies on its cycle detector. Either way the call must RETURN. The test
    // proves termination simply by completing: an infinite loop would time the
    // suite out. The regular (non-cycle) file under root is still reported,
    // proving the cycle did not abort the whole walk.
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = TestDir.init(inner_allocator);
            defer tmp_dir.deinit();

            try tmp_dir.dir().createDir(testing.io, "root", .default_dir);
            var root = try tmp_dir.dir().openDir(testing.io, "root", .{});
            defer root.close(testing.io);
            (try root.createFile(testing.io, "f.txt", .{})).close(testing.io);
            // root/loop -> . (symlink to its own directory) creates a cycle
            // that -L would follow forever absent a stopping mechanism.
            root.symLink(testing.io, ".", "loop", .{}) catch return error.SkipZigTest;

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const base = try characterizationTmpRealpath(inner_allocator, &tmp_dir, &path_buf);
            const root_path = try std.fmt.allocPrint(inner_allocator, "{s}/root", .{base});

            const ownership = common.user_group.OwnershipSpec{
                .user = characterization_uid,
                .group = characterization_gid,
            };
            const options = ChownOptions{
                .recursive = true,
                .traverse_all_symlinks = true,
                .verbose = true,
            };

            var stdout_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stdout_aw.deinit();
            var stderr_aw: std.Io.Writer.Allocating = .init(inner_allocator);
            defer stderr_aw.deinit();

            // Must return (not hang). Per-entry errors from the cycle are
            // tolerated: the current code surfaces ELOOP from the kernel; a
            // future walker surfaces its own cycle stop. Both must terminate.
            chownWalk(
                testing.io,
                root_path,
                ownership,
                options,
                inner_allocator,
                &stdout_aw.writer,
                &stderr_aw.writer,
            ) catch {};

            const out = stdout_aw.writer.buffered();
            const file_marker = try std.fmt.allocPrint(
                inner_allocator,
                "'{s}/root/f.txt'",
                .{base},
            );
            try testing.expect(characterizationReported(out, file_marker));
        }
    }.testFn);
}
