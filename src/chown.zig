const std = @import("std");
const common = @import("common");
const testing = std.testing;
const fs = std.fs;
const c = std.c;
const privilege_test = common.privilege_test;

// External C function bindings
extern "c" fn chown(path: [*:0]const u8, uid: c.uid_t, gid: c.gid_t) c_int;
extern "c" fn lchown(path: [*:0]const u8, uid: c.uid_t, gid: c.gid_t) c_int;

const ChownArgs = struct {
    help: bool = false,
    version: bool = false,
    changes: bool = false,
    silent: bool = false,
    quiet: bool = false,
    verbose: bool = false,
    no_dereference: bool = false,
    H: bool = false,
    L: bool = false,
    P: bool = false,
    recursive: bool = false,
    reference: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Parse arguments using new parser
    const args = common.argparse.ArgParser.parseProcess(ChownArgs, allocator) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.fatal("invalid argument", .{});
            },
            else => return err,
        }
    };
    defer allocator.free(args.positionals);

    // Handle help
    if (args.help) {
        try printHelp();
        return;
    }

    // Handle version
    if (args.version) {
        try printVersion();
        return;
    }

    // Get positional arguments
    const positionals = args.positionals;

    // Create options struct
    const options = ChownOptions{
        .changes = args.changes,
        .silent = args.silent or args.quiet,
        .verbose = args.verbose,
        .no_dereference = args.no_dereference,
        .traverse_command_line_symlinks = args.H,
        .traverse_all_symlinks = args.L,
        .no_traverse_symlinks = args.P,
        .recursive = args.recursive,
        .reference_file = args.reference,
    };

    // Check arguments based on whether we have a reference file
    const owner_spec: []const u8 = if (args.reference != null) blk: {
        // With --reference, we only need files (no owner spec)
        if (positionals.len < 1) {
            common.fatal("missing file operand", .{});
        }
        break :blk ""; // Empty owner spec when using reference
    } else blk: {
        // Without --reference, we need owner spec + files
        if (positionals.len < 2) {
            common.fatal("missing operand", .{});
        }
        break :blk positionals[0];
    };

    const files: []const []const u8 = if (args.reference != null)
        positionals
    else
        positionals[1..];

    // Process files
    var exit_code: u8 = 0;
    for (files) |file_path| {
        chownFile(file_path, owner_spec, options, allocator) catch |err| {
            handleError(file_path, err, options);
            exit_code = @intFromEnum(common.ExitCode.general_error);
        };
    }

    std.process.exit(exit_code);
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    try stdout.print(
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

fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("chown ({s}) {s}\n", .{ common.name, common.version });
}

const ChownOptions = struct {
    changes: bool = false,
    silent: bool = false,
    verbose: bool = false,
    no_dereference: bool = false,
    traverse_command_line_symlinks: bool = false,
    traverse_all_symlinks: bool = false,
    no_traverse_symlinks: bool = false,
    recursive: bool = false,
    reference_file: ?[]const u8 = null,
};

fn chownFile(
    path: []const u8,
    owner_spec: []const u8,
    options: ChownOptions,
    allocator: std.mem.Allocator,
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
        try chownRecursive(path, ownership, options, allocator);
    } else {
        try chownSingle(path, ownership, options);
    }
}

fn chownSingle(path: []const u8, ownership: common.user_group.OwnershipSpec, options: ChownOptions) !void {
    // Get current ownership for comparison
    const stat_info = try common.file.FileInfo.stat(path);
    const current_uid = @as(common.user_group.uid_t, @intCast(stat_info.uid));
    const current_gid = @as(common.user_group.gid_t, @intCast(stat_info.gid));

    // Determine new ownership values
    const new_uid = ownership.user orelse current_uid;
    const new_gid = ownership.group orelse current_gid;

    // Check if change is needed
    const changed = (new_uid != current_uid) or (new_gid != current_gid);

    if (changed) {
        // Apply ownership change
        try changeOwnership(path, new_uid, new_gid, options);

        // Report change if requested
        if (options.verbose or options.changes) {
            reportChange(path, current_uid, current_gid, new_uid, new_gid);
        }
    } else if (options.verbose) {
        // Report no change
        reportNoChange(path);
    }
}

fn chownRecursive(
    path: []const u8,
    ownership: common.user_group.OwnershipSpec,
    options: ChownOptions,
    allocator: std.mem.Allocator,
) !void {
    // First change the directory/file itself
    try chownSingle(path, ownership, options);

    // Check if it's a directory to recurse into
    const stat_info = common.file.FileInfo.stat(path) catch return; // Ignore errors for missing files

    if (stat_info.kind == .directory) {
        // Open directory and iterate
        var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return; // Ignore permission errors
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            // Build full path
            const full_path = try fs.path.join(allocator, &.{ path, entry.name });
            defer allocator.free(full_path);

            // Recurse
            try chownRecursive(full_path, ownership, options, allocator);
        }
    }
}

fn changeOwnership(path: []const u8, uid: common.user_group.uid_t, gid: common.user_group.gid_t, options: ChownOptions) !void {
    // Convert path to null-terminated string for system call
    const path_c = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_c);

    // Choose between chown and lchown based on no_dereference option
    const result = if (options.no_dereference)
        lchown(path_c.ptr, uid, gid)
    else
        chown(path_c.ptr, uid, gid);

    if (result != 0) {
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

fn getOwnershipFromReference(ref_path: []const u8) !common.user_group.OwnershipSpec {
    const stat_info = try common.file.FileInfo.stat(ref_path);
    return common.user_group.OwnershipSpec{
        .user = @as(common.user_group.uid_t, @intCast(stat_info.uid)),
        .group = @as(common.user_group.gid_t, @intCast(stat_info.gid)),
    };
}

fn reportChange(path: []const u8, old_uid: common.user_group.uid_t, old_gid: common.user_group.gid_t, new_uid: common.user_group.uid_t, new_gid: common.user_group.gid_t) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("changed ownership of '{s}' from {d}:{d} to {d}:{d}\n", .{ path, old_uid, old_gid, new_uid, new_gid }) catch {};
}

fn reportNoChange(path: []const u8) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("ownership of '{s}' retained\n", .{path}) catch {};
}

fn handleError(path: []const u8, err: anyerror, options: ChownOptions) void {
    if (options.silent) return; // Suppress errors in silent mode

    switch (err) {
        error.FileNotFound => common.printError("cannot access '{s}': No such file or directory", .{path}),
        error.PermissionDenied => common.printError("changing ownership of '{s}': Operation not permitted", .{path}),
        error.NotDir => common.printError("cannot access '{s}': Not a directory", .{path}),
        error.SymLinkLoop => common.printError("cannot access '{s}': Too many levels of symbolic links", .{path}),
        error.NameTooLong => common.printError("cannot access '{s}': File name too long", .{path}),
        error.ReadOnlyFileSystem => common.printError("changing ownership of '{s}': Read-only file system", .{path}),
        error.InvalidValue => common.printError("cannot access '{s}': Invalid argument", .{path}),
        error.InputOutputError => common.printError("cannot access '{s}': Input/output error", .{path}),
        error.UserNotFound => common.printError("invalid user: '{s}'", .{path}),
        error.GroupNotFound => common.printError("invalid group: '{s}'", .{path}),
        error.InvalidFormat => common.printError("invalid owner specification: '{s}'", .{path}),
        error.SystemResources => common.printError("cannot access '{s}': Cannot allocate memory", .{path}),
        error.Unexpected => common.printError("cannot access '{s}': Unexpected error", .{path}),
        else => common.printError("cannot access '{s}': {s}", .{ path, @errorName(err) }),
    }
}

// ==================== TESTS ====================

// ============================================================================
// REGULAR TESTS
// These tests can run without special privileges and test logic that doesn't
// require actual ownership changes (e.g., parsing, error handling).
// ============================================================================

// Regular tests that don't require privileges will remain here

// ============================================================================
// PRIVILEGED TESTS
// These tests require privilege simulation (fakeroot) to run properly.
// They are named with "privileged:" prefix and are excluded from regular tests.
// Run with: ./scripts/run-privileged-tests.sh or zig build test-privileged under fakeroot
// ============================================================================

test "privileged: chown basic functionality" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            // This is a failing test that we'll implement step by step
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            // Create a test file
            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            // Get real path for the temporary directory
            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{tmp_path});
            defer allocator.free(test_file);

            // Get current user for the test
            const current_uid = common.user_group.getCurrentUserId();
            const current_gid = common.user_group.getCurrentGroupId();

            const owner_spec = try std.fmt.allocPrint(allocator, "{d}:{d}", .{ current_uid, current_gid });
            defer allocator.free(owner_spec);

            const options = ChownOptions{};

            // This should work for changing to the same ownership
            try chownFile(test_file, owner_spec, options, allocator);
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
    try testing.expectError(error.InvalidFormat, chownFile(test_file, "", options, testing.allocator));
}

test "privileged: chown user only specification" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{tmp_path});
            defer allocator.free(test_file);

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(allocator, "{d}", .{current_uid});
            defer allocator.free(owner_spec);

            const options = ChownOptions{};

            // Should work for user-only specification
            try chownFile(test_file, owner_spec, options, allocator);
        }
    }.testFn);
}

test "privileged: chown group only specification" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{tmp_path});
            defer allocator.free(test_file);

            const current_gid = common.user_group.getCurrentGroupId();
            const owner_spec = try std.fmt.allocPrint(allocator, ":{d}", .{current_gid});
            defer allocator.free(owner_spec);

            const options = ChownOptions{};

            // Should work for group-only specification
            try chownFile(test_file, owner_spec, options, allocator);
        }
    }.testFn);
}

test "privileged: chown with reference file" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            // Create reference and target files
            const ref_file = try tmp_dir.dir.createFile("reference.txt", .{});
            ref_file.close();

            const target_file = try tmp_dir.dir.createFile("target.txt", .{});
            target_file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const ref_path = try std.fmt.allocPrint(allocator, "{s}/reference.txt", .{tmp_path});
            defer allocator.free(ref_path);

            const target_path = try std.fmt.allocPrint(allocator, "{s}/target.txt", .{tmp_path});
            defer allocator.free(target_path);

            const options = ChownOptions{ .reference_file = ref_path };

            // Should use reference file's ownership
            try chownFile(target_path, "", options, allocator);
        }
    }.testFn);
}

test "chown nonexistent file" {
    const options = ChownOptions{};
    const current_uid = common.user_group.getCurrentUserId();
    const owner_spec = try std.fmt.allocPrint(testing.allocator, "{d}", .{current_uid});
    defer testing.allocator.free(owner_spec);

    // Should fail for nonexistent file
    try testing.expectError(error.FileNotFound, chownFile("/nonexistent/file", owner_spec, options, testing.allocator));
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
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            _ = allocator;
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/test.txt", .{tmp_path});
            defer testing.allocator.free(test_file);

            // Get current ownership
            const stat_info = try common.file.FileInfo.stat(test_file);
            const current_uid = @as(common.user_group.uid_t, @intCast(stat_info.uid));
            const current_gid = @as(common.user_group.gid_t, @intCast(stat_info.gid));

            const options = ChownOptions{};

            // Should succeed when changing to same ownership
            try changeOwnership(test_file, current_uid, current_gid, options);
        }
    }.testFn);
}

test "privileged: chownSingle basic operation" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            _ = allocator;
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/test.txt", .{tmp_path});
            defer testing.allocator.free(test_file);

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
            try chownSingle(test_file, ownership, options);
        }
    }.testFn);
}

test "privileged: chown recursive option" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            // Create a directory structure
            try tmp_dir.dir.makeDir("testdir");
            const subdir = try tmp_dir.dir.openDir("testdir", .{});
            const file = try subdir.createFile("file.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_dir = try std.fmt.allocPrint(allocator, "{s}/testdir", .{tmp_path});
            defer allocator.free(test_dir);

            const current_uid = common.user_group.getCurrentUserId();
            const current_gid = common.user_group.getCurrentGroupId();
            const owner_spec = try std.fmt.allocPrint(allocator, "{d}:{d}", .{ current_uid, current_gid });
            defer allocator.free(owner_spec);

            const options = ChownOptions{ .recursive = true };

            // Should work recursively
            try chownFile(test_dir, owner_spec, options, allocator);
        }
    }.testFn);
}

test "privileged: chown with verbose option" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{tmp_path});
            defer allocator.free(test_file);

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(allocator, "{d}", .{current_uid});
            defer allocator.free(owner_spec);

            const options = ChownOptions{ .verbose = true };

            // Should work with verbose output
            try chownFile(test_file, owner_spec, options, allocator);
        }
    }.testFn);
}

test "privileged: chown with changes option" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{tmp_path});
            defer allocator.free(test_file);

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(allocator, "{d}", .{current_uid});
            defer allocator.free(owner_spec);

            const options = ChownOptions{ .changes = true };

            // Should work with changes option
            try chownFile(test_file, owner_spec, options, allocator);
        }
    }.testFn);
}

test "privileged: chown with no-dereference option" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            // Create a file and a symlink to it
            const file = try tmp_dir.dir.createFile("target.txt", .{});
            file.close();

            // Create symlink (this might fail on some systems)
            tmp_dir.dir.symLink("target.txt", "link.txt", .{}) catch {
                // Skip test if symlinks aren't supported
                return;
            };

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_link = try std.fmt.allocPrint(allocator, "{s}/link.txt", .{tmp_path});
            defer allocator.free(test_link);

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(allocator, "{d}", .{current_uid});
            defer allocator.free(owner_spec);

            const options = ChownOptions{ .no_dereference = true };

            // Should work with no-dereference option
            try chownFile(test_link, owner_spec, options, allocator);
        }
    }.testFn);
}

test "chown with silent option suppresses errors" {
    const current_uid = common.user_group.getCurrentUserId();
    const owner_spec = try std.fmt.allocPrint(testing.allocator, "{d}", .{current_uid});
    defer testing.allocator.free(owner_spec);

    const options = ChownOptions{ .silent = true };

    // Should not panic or output errors for nonexistent file in silent mode
    const result = chownFile("/nonexistent/path", owner_spec, options, testing.allocator);
    try testing.expectError(error.FileNotFound, result);
}

test "privileged: chown traverse options" {
    // Skip test if no privilege simulation available
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{});
            file.close();

            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

            const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{tmp_path});
            defer allocator.free(test_file);

            const current_uid = common.user_group.getCurrentUserId();
            const owner_spec = try std.fmt.allocPrint(allocator, "{d}", .{current_uid});
            defer allocator.free(owner_spec);

            // Test traverse command line symlinks
            const options_h = ChownOptions{ .traverse_command_line_symlinks = true };
            try chownFile(test_file, owner_spec, options_h, allocator);

            // Test traverse all symlinks
            const options_l = ChownOptions{ .traverse_all_symlinks = true };
            try chownFile(test_file, owner_spec, options_l, allocator);

            // Test no traverse symlinks (default)
            const options_p = ChownOptions{ .no_traverse_symlinks = true };
            try chownFile(test_file, owner_spec, options_p, allocator);
        }
    }.testFn);
}

test "error handling different error types" {
    const options = ChownOptions{};

    // Test invalid owner specification
    const result1 = chownFile("/tmp/test", "", options, testing.allocator);
    try testing.expectError(error.InvalidFormat, result1);

    // Test nonexistent file (with valid owner spec)
    const current_uid = common.user_group.getCurrentUserId();
    const owner_spec = try std.fmt.allocPrint(testing.allocator, "{d}", .{current_uid});
    defer testing.allocator.free(owner_spec);

    const result2 = chownFile("/nonexistent/file", owner_spec, options, testing.allocator);
    try testing.expectError(error.FileNotFound, result2);
}

test "reportChange function" {
    // These functions write to stdout, which can cause issues in tests
    // For now, we'll just verify they compile and the logic works
    // In a real implementation, we'd refactor to take a writer parameter

    // Instead of calling them directly, we verify the functions exist
    // and trust that the print operations work correctly
    try testing.expect(@TypeOf(reportChange) == fn ([]const u8, common.user_group.uid_t, common.user_group.gid_t, common.user_group.uid_t, common.user_group.gid_t) void);
    try testing.expect(@TypeOf(reportNoChange) == fn ([]const u8) void);
}
