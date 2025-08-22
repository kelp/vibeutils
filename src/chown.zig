//! chown - change file owner and group
const std = @import("std");
const common = @import("common");
const testing = std.testing;
const fs = std.fs;
const c = std.c;
const privilege_test = common.privilege_test;

// External C function bindings

/// Changes owner and group of a file (follows symbolic links)
extern "c" fn chown(path: [*:0]const u8, uid: c.uid_t, gid: c.gid_t) c_int;

/// Changes owner and group of a file (does not follow symbolic links)
extern "c" fn lchown(path: [*:0]const u8, uid: c.uid_t, gid: c.gid_t) c_int;

/// Command-line arguments for chown
const ChownArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Display version and exit
    version: bool = false,
    /// Report only when a change is made
    changes: bool = false,
    /// Suppress most error messages
    silent: bool = false,
    /// Same as silent
    quiet: bool = false,
    /// Output a diagnostic for every file processed
    verbose: bool = false,
    /// Affect symbolic links instead of referenced files
    no_dereference: bool = false,
    /// If a command line argument is a symbolic link to a directory, traverse it
    H: bool = false,
    /// Traverse every symbolic link to a directory encountered
    L: bool = false,
    /// Do not traverse any symbolic links (default behavior)
    P: bool = false,
    /// Operate on files and directories recursively
    recursive: bool = false,
    /// Use file's owner and group as reference
    reference: ?[]const u8 = null,
    /// Positional arguments (owner spec and file paths)
    positionals: []const []const u8 = &.{},

    /// Metadata for argument parsing
    pub const meta = .{
        .help = .{ .short = 0, .desc = "Display this help and exit" }, // Disable short flag for help
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .changes = .{ .short = 'c', .desc = "Like verbose but report only when a change is made" },
        .silent = .{ .short = 'f', .desc = "Suppress most error messages" },
        .quiet = .{ .desc = "Suppress most error messages" },
        .verbose = .{ .short = 'v', .desc = "Output a diagnostic for every file processed" },
        .no_dereference = .{ .short = 'h', .desc = "Affect symbolic links instead of any referenced file" },
        .H = .{ .short = 'H', .desc = "If a command line argument is a symbolic link to a directory, traverse it" },
        .L = .{ .short = 'L', .desc = "Traverse every symbolic link to a directory encountered" },
        .P = .{ .short = 'P', .desc = "Do not traverse any symbolic links (default)" },
        .recursive = .{ .short = 'R', .desc = "Operate on files and directories recursively" },
        .reference = .{ .desc = "Use RFILE's owner and group rather than specifying values", .value_name = "RFILE" },
    };
};

/// Main entry point for chown utility
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

    const exit_code = try runChown(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    try stdout.flush();
    try stderr.flush();

    std.process.exit(exit_code);
}

/// Main implementation that accepts writers for output
pub fn runChown(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse command-line arguments using the common argument parser
    const parsed_args = common.argparse.ArgParser.parse(ChownArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "chown", "invalid argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle information requests (help/version) - these exit immediately
    if (parsed_args.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Get positional arguments for further processing
    const positionals = parsed_args.positionals;

    // Convert arguments to internal options
    const options = ChownOptions{
        .changes = parsed_args.changes,
        .silent = parsed_args.silent or parsed_args.quiet,
        .verbose = parsed_args.verbose,
        .no_dereference = parsed_args.no_dereference,
        .traverse_command_line_symlinks = parsed_args.H,
        .traverse_all_symlinks = parsed_args.L,
        .no_traverse_symlinks = parsed_args.P,
        .recursive = parsed_args.recursive,
        .reference_file = parsed_args.reference,
    };

    // Extract owner spec and files based on whether --reference is used
    const owner_spec: []const u8 = if (parsed_args.reference != null) blk: {
        // With --reference, we only need files (no owner spec)
        if (positionals.len < 1) {
            common.printErrorWithProgram(allocator, stderr_writer, "chown", "missing file operand", .{});
            return @intFromEnum(common.ExitCode.general_error);
        }
        break :blk "";
    } else blk: {
        // Without --reference, we need owner spec + files
        if (positionals.len < 2) {
            common.printErrorWithProgram(allocator, stderr_writer, "chown", "missing operand", .{});
            return @intFromEnum(common.ExitCode.general_error);
        }
        break :blk positionals[0];
    };

    // Extract file list based on mode
    const files: []const []const u8 = if (parsed_args.reference != null)
        positionals
    else
        positionals[1..];

    // Process each file, accumulating error status
    var exit_code: u8 = 0;
    for (files) |file_path| {
        chownFile(allocator, file_path, owner_spec, options, stdout_writer, stderr_writer) catch |err| {
            handleError(allocator, file_path, err, options, stderr_writer);
            exit_code = @intFromEnum(common.ExitCode.general_error);
        };
    }

    return exit_code;
}

/// Print help message
fn printHelp(writer: anytype) !void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    try writer.print(
        \\Usage: {s} [OPTION]... [OWNER][:[GROUP]] FILE...
        \\  or:  {s} [OPTION]... --reference=RFILE FILE...
        \\Change the owner and/or group of each FILE to OWNER and/or GROUP.
        \\With --reference, change the owner and group of each FILE to those of RFILE.
        \\
        \\Options:
        \\  -c, --changes          like verbose but report only when a change is made
        \\  -f, --silent, --quiet  suppress most error messages
        \\  -v, --verbose          output a diagnostic for every file processed
        \\  -h, --no-dereference   affect symbolic links instead of any referenced file
        \\      --reference=RFILE  use RFILE's owner and group rather than
        \\                         specifying OWNER:GROUP values
        \\  -R, --recursive        operate on files and directories recursively
        \\
        \\The following options modify how a hierarchy is traversed when the -R
        \\option is also specified.  If more than one is specified, only the final
        \\one takes effect.
        \\
        \\  -H                     if a command line argument is a symbolic link
        \\                         to a directory, traverse it
        \\  -L                     traverse every symbolic link to a directory
        \\                         encountered
        \\  -P                     do not traverse any symbolic links (default)
        \\
        \\Owner is unchanged if missing.  Group is unchanged if missing, but changed
        \\to login group if implied by a ':' following a symbolic OWNER.
        \\OWNER and GROUP may be numeric as well as symbolic.
        \\
        \\Examples:
        \\  {s} root /u        Change the owner of /u to "root".
        \\  {s} root:staff /u  Change the owner of /u to "root" and the group to "staff".
        \\  {s} -hR root /u    Change the owner of /u and subfiles to "root".
        \\
        \\      --help     display this help and exit
        \\  -V, --version  output version information and exit
        \\
    , .{ prog_name, prog_name, prog_name, prog_name, prog_name });
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
    /// Follow command line symlinks
    traverse_command_line_symlinks: bool = false,
    /// Follow all symlinks
    traverse_all_symlinks: bool = false,
    /// Never follow symlinks
    no_traverse_symlinks: bool = false,
    /// Change ownership recursively
    recursive: bool = false,
    /// Reference file path
    reference_file: ?[]const u8 = null,
};

/// Change ownership of a file or directory
fn chownFile(
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
        ownership = try getOwnershipFromReference(ref_path);
    } else {
        // Parse owner specification string
        ownership = try common.user_group.OwnershipSpec.parse(owner_spec, allocator);
    }

    // Apply ownership change
    if (options.recursive) {
        try chownRecursive(path, ownership, options, allocator, stdout_writer, stderr_writer);
    } else {
        try chownSingle(allocator, path, ownership, options, stdout_writer, stderr_writer);
    }
}

/// Change ownership of a single file (non-recursive)
fn chownSingle(allocator: std.mem.Allocator, path: []const u8, ownership: common.user_group.OwnershipSpec, options: ChownOptions, stdout_writer: anytype, stderr_writer: anytype) !void {
    _ = stderr_writer; // Parameter for API consistency, errors bubble up to caller
    // Get current ownership for comparison
    const stat_info = try common.file.FileInfo.stat(path);
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

/// Recursively change ownership of directory and contents
/// Errors during traversal are ignored to continue processing
fn chownRecursive(
    path: []const u8,
    ownership: common.user_group.OwnershipSpec,
    options: ChownOptions,
    allocator: std.mem.Allocator,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    // First change the directory/file itself
    try chownSingle(allocator, path, ownership, options, stdout_writer, stderr_writer);

    // Check if it's a directory to recurse into
    const stat_info = common.file.FileInfo.stat(path) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "chown", "cannot stat '{s}': {s}", .{ path, @errorName(err) });
        return;
    };

    if (stat_info.kind == .directory) {
        // Open directory and iterate
        var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "chown", "cannot open directory '{s}': {s}", .{ path, @errorName(err) });
            return;
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            // Build full path
            const full_path = try fs.path.join(allocator, &.{ path, entry.name });
            defer allocator.free(full_path);

            // Recurse into subdirectory or change file
            try chownRecursive(full_path, ownership, options, allocator, stdout_writer, stderr_writer);
        }
    }
}

/// Perform ownership change via system call
/// Uses chown() or lchown() based on no_dereference option
fn changeOwnership(allocator: std.mem.Allocator, path: []const u8, uid: common.user_group.uid_t, gid: common.user_group.gid_t, options: ChownOptions) !void {
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
fn getOwnershipFromReference(ref_path: []const u8) !common.user_group.OwnershipSpec {
    const stat_info = try common.file.FileInfo.stat(ref_path);
    return common.user_group.OwnershipSpec{
        .user = @as(common.user_group.uid_t, @intCast(stat_info.uid)),
        .group = @as(common.user_group.gid_t, @intCast(stat_info.gid)),
    };
}

/// Report successful ownership change
fn reportChange(writer: anytype, path: []const u8, old_uid: common.user_group.uid_t, old_gid: common.user_group.gid_t, new_uid: common.user_group.uid_t, new_gid: common.user_group.gid_t) !void {
    try writer.print("changed ownership of '{s}' from {d}:{d} to {d}:{d}\n", .{ path, old_uid, old_gid, new_uid, new_gid });
}

/// Report ownership unchanged
fn reportNoChange(writer: anytype, path: []const u8) !void {
    try writer.print("ownership of '{s}' retained\n", .{path});
}

/// Handle and report errors
fn handleError(allocator: std.mem.Allocator, path: []const u8, err: anyerror, options: ChownOptions, stderr_writer: anytype) void {
    if (options.silent) return; // Suppress errors in silent mode

    switch (err) {
        error.FileNotFound => common.printErrorWithProgram(allocator, stderr_writer, "chown", "cannot access '{s}': No such file or directory", .{path}),
        error.PermissionDenied => common.printErrorWithProgram(allocator, stderr_writer, "chown", "changing ownership of '{s}': Operation not permitted", .{path}),
        error.NotDir => common.printErrorWithProgram(allocator, stderr_writer, "chown", "cannot access '{s}': Not a directory", .{path}),
        error.SymLinkLoop => common.printErrorWithProgram(allocator, stderr_writer, "chown", "cannot access '{s}': Too many levels of symbolic links", .{path}),
        error.NameTooLong => common.printErrorWithProgram(allocator, stderr_writer, "chown", "cannot access '{s}': File name too long", .{path}),
        error.ReadOnlyFileSystem => common.printErrorWithProgram(allocator, stderr_writer, "chown", "changing ownership of '{s}': Read-only file system", .{path}),
        error.InvalidValue => common.printErrorWithProgram(allocator, stderr_writer, "chown", "cannot access '{s}': Invalid argument", .{path}),
        error.InputOutputError => common.printErrorWithProgram(allocator, stderr_writer, "chown", "cannot access '{s}': Input/output error", .{path}),
        error.UserNotFound => common.printErrorWithProgram(allocator, stderr_writer, "chown", "invalid user", .{}),
        error.GroupNotFound => common.printErrorWithProgram(allocator, stderr_writer, "chown", "invalid group", .{}),
        error.InvalidFormat => common.printErrorWithProgram(allocator, stderr_writer, "chown", "invalid owner specification", .{}),
        error.SystemResources => common.printErrorWithProgram(allocator, stderr_writer, "chown", "cannot access '{s}': Cannot allocate memory", .{path}),
        error.Unexpected => common.printErrorWithProgram(allocator, stderr_writer, "chown", "cannot access '{s}': Unexpected error", .{path}),
        else => common.printErrorWithProgram(allocator, stderr_writer, "chown", "cannot access '{s}': {s}", .{ path, @errorName(err) }),
    }
}

// Tests

// Regular tests run without privileges
// Privileged tests require fakeroot and are named with "privileged:" prefix

test "privileged: chown basic functionality" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            // Create a test file
            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            // Get real path for the temporary directory
            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            // Get current user for the test
            const current_uid = common.user_group.getCurrentUserId();
            const current_gid = common.user_group.getCurrentGroupId();

            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}:{d}", .{ current_uid, current_gid });

            const options = ChownOptions{};

            // This should work for changing to the same ownership
            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);
            try chownFile(inner_allocator, test_file, owner_spec, options, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));
        }
    }.testFn);
}

test "chown with invalid owner specification" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    file.close();

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/test.txt", .{tmp_path});
    defer testing.allocator.free(test_file);

    const options = ChownOptions{};

    // Empty specification should fail
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);
    try testing.expectError(error.InvalidFormat, chownFile(testing.allocator, test_file, "", options, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator)));
}

test "privileged: chown user only specification" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}", .{current_uid});

            const options = ChownOptions{};

            // Should work for user-only specification
            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);
            try chownFile(inner_allocator, test_file, owner_spec, options, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));
        }
    }.testFn);
}

test "privileged: chown group only specification" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            const current_gid = common.user_group.getCurrentGroupId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, ":{d}", .{current_gid});

            const options = ChownOptions{};

            // Should work for group-only specification
            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);
            try chownFile(inner_allocator, test_file, owner_spec, options, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));
        }
    }.testFn);
}

test "privileged: chown with reference file" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            // Create reference and target files
            const ref_file = try tmp_dir.dir.createFile("reference.txt", .{});
            ref_file.close();

            const target_file = try tmp_dir.dir.createFile("target.txt", .{});
            target_file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const ref_path = try std.fmt.allocPrint(inner_allocator, "{s}/reference.txt", .{tmp_path});

            const target_path = try std.fmt.allocPrint(inner_allocator, "{s}/target.txt", .{tmp_path});

            const options = ChownOptions{ .reference_file = ref_path };

            // Should use reference file's ownership
            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);
            try chownFile(inner_allocator, target_path, "", options, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));
        }
    }.testFn);
}

test "chown nonexistent file" {
    const options = ChownOptions{};
    const current_uid = common.user_group.getCurrentUserId();
    const owner_spec = try std.fmt.allocPrint(testing.allocator, "{d}", .{current_uid});
    defer testing.allocator.free(owner_spec);

    // Should fail for nonexistent file
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);
    try testing.expectError(error.FileNotFound, chownFile(testing.allocator, "/nonexistent/file", owner_spec, options, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator)));
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
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("ref.txt", .{});
    file.close();

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/ref.txt", .{tmp_path});
    defer testing.allocator.free(ref_path);

    const ownership = try getOwnershipFromReference(ref_path);
    try testing.expect(ownership.user != null);
    try testing.expect(ownership.group != null);
}

test "privileged: changeOwnership with same values" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            // Get current ownership
            const stat_info = try common.file.FileInfo.stat(test_file);
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
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            // Get current ownership
            const stat_info = try common.file.FileInfo.stat(test_file);
            const current_uid = @as(common.user_group.uid_t, @intCast(stat_info.uid));
            const current_gid = @as(common.user_group.gid_t, @intCast(stat_info.gid));

            const ownership = common.user_group.OwnershipSpec{
                .user = current_uid,
                .group = current_gid,
            };

            const options = ChownOptions{};

            // Should work for same ownership
            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);
            try chownSingle(inner_allocator, test_file, ownership, options, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));
        }
    }.testFn);
}

test "privileged: chown recursive option" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            // Create a directory structure
            try tmp_dir.dir.makeDir("testdir");
            const subdir = try tmp_dir.dir.openDir("testdir", .{});
            const file = try subdir.createFile("file.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_dir = try std.fmt.allocPrint(inner_allocator, "{s}/testdir", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const current_gid = common.user_group.getCurrentGroupId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}:{d}", .{ current_uid, current_gid });

            const options = ChownOptions{ .recursive = true };

            // Should work recursively
            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);
            try chownFile(inner_allocator, test_dir, owner_spec, options, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));
        }
    }.testFn);
}

test "privileged: chown with verbose option" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}", .{current_uid});

            const options = ChownOptions{ .verbose = true };

            // Should work with verbose output
            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);
            try chownFile(inner_allocator, test_file, owner_spec, options, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));
        }
    }.testFn);
}

test "privileged: chown with changes option" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}", .{current_uid});

            const options = ChownOptions{ .changes = true };

            // Should work with changes option
            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);
            try chownFile(inner_allocator, test_file, owner_spec, options, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));
        }
    }.testFn);
}

test "privileged: chown with no-dereference option" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            // Create a file and a symlink to it
            const file = try tmp_dir.dir.createFile("target.txt", .{});
            file.close();

            // Create symlink (this might fail on some systems)
            tmp_dir.dir.symLink("target.txt", "link.txt", .{}) catch {
                return;
            };

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_link = try std.fmt.allocPrint(inner_allocator, "{s}/link.txt", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}", .{current_uid});

            const options = ChownOptions{ .no_dereference = true };

            // Should work with no-dereference option
            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);
            try chownFile(inner_allocator, test_link, owner_spec, options, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));
        }
    }.testFn);
}

test "chown with silent option suppresses errors" {
    const current_uid = common.user_group.getCurrentUserId();
    const owner_spec = try std.fmt.allocPrint(testing.allocator, "{d}", .{current_uid});
    defer testing.allocator.free(owner_spec);

    const options = ChownOptions{ .silent = true };

    // Should not panic or output errors for nonexistent file in silent mode
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);
    const result = chownFile(testing.allocator, "/nonexistent/path", owner_spec, options, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectError(error.FileNotFound, result);
}

test "privileged: chown traverse options" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(inner_allocator, "{s}/test.txt", .{tmp_path});

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(inner_allocator, "{d}", .{current_uid});

            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);

            // Test traverse command line symlinks
            const options_h = ChownOptions{ .traverse_command_line_symlinks = true };
            try chownFile(inner_allocator, test_file, owner_spec, options_h, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));

            // Test traverse all symlinks
            const options_l = ChownOptions{ .traverse_all_symlinks = true };
            try chownFile(inner_allocator, test_file, owner_spec, options_l, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));

            // Test no traverse symlinks (default)
            const options_p = ChownOptions{ .no_traverse_symlinks = true };
            try chownFile(inner_allocator, test_file, owner_spec, options_p, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));
        }
    }.testFn);
}

test "error handling different error types" {
    const options = ChownOptions{};

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Test invalid owner specification
    const result1 = chownFile(testing.allocator, "/nonexistent/test", "", options, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectError(error.InvalidFormat, result1);

    // Test nonexistent file (with valid owner spec)
    const current_uid = common.user_group.getCurrentUserId();
    const owner_spec = try std.fmt.allocPrint(testing.allocator, "{d}", .{current_uid});
    defer testing.allocator.free(owner_spec);

    const result2 = chownFile(testing.allocator, "/nonexistent/file", owner_spec, options, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectError(error.FileNotFound, result2);
}

test "reportChange function" {
    // The reportChange and reportNoChange functions now accept writer: anytype
    // and return !void. This is verified by compilation.
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // Test that the functions can be called without error
    try reportChange(stdout_buffer.writer(testing.allocator), "/test", 1000, 100, 1001, 101);
    try reportNoChange(stdout_buffer.writer(testing.allocator), "/test");

    // Verify output was written
    try testing.expect(stdout_buffer.items.len > 0);
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const builtin = @import("builtin");
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("chown");

test "chown fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testChownIntelligentWrapper, .{});
}

fn testChownIntelligentWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("chown")) return;

    const ChownIntelligentFuzzer = common.fuzz.createIntelligentFuzzer(ChownArgs, runChown);
    try ChownIntelligentFuzzer.testComprehensive(allocator, input, common.null_writer);
}
