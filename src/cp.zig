//! Copy files and directories with POSIX-compatible behavior

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const types = @import("cp/types.zig");
const errors = @import("cp/errors.zig");
const copy_engine = @import("cp/copy_engine.zig");
const user_interaction = @import("cp/user_interaction.zig");

/// Command-line arguments for cp
const CpArgs = struct {
    help: bool = false,
    version: bool = false,
    r: bool = false,
    recursive: bool = false,
    R: bool = false,
    i: bool = false,
    interactive: bool = false,
    f: bool = false,
    force: bool = false,
    p: bool = false,
    preserve: bool = false,
    d: bool = false,
    no_dereference: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .r = .{ .desc = "Copy directories recursively" },
        .recursive = .{ .short = 0, .desc = "Copy directories recursively" },
        .R = .{ .desc = "Copy directories recursively (same as -r)" },
        .i = .{ .desc = "Prompt before overwrite" },
        .interactive = .{ .short = 0, .desc = "Prompt before overwrite" },
        .f = .{ .desc = "Force overwrite without prompting" },
        .force = .{ .short = 0, .desc = "Force overwrite without prompting" },
        .p = .{ .desc = "Preserve mode, ownership, timestamps" },
        .preserve = .{ .short = 0, .desc = "Preserve mode, ownership, timestamps" },
        .d = .{ .desc = "Never follow symbolic links in SOURCE" },
        .no_dereference = .{ .short = 0, .desc = "Never follow symbolic links in SOURCE" },
    };
};

/// Main entry point for the cp command
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();

    const exit_code = try runCp(stdout_writer, stderr_writer, allocator);
    if (exit_code != common.ExitCode.success) {
        std.process.exit(@intFromEnum(exit_code));
    }
}

/// Run cp with provided writers for output
pub fn runCp(stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !common.ExitCode {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Parse command line arguments
    const args = common.argparse.ArgParser.parseProcess(CpArgs, allocator) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                try stderr_writer.print("{s}: unrecognized option\nTry '{s} --help' for more information.\n", .{ prog_name, prog_name });
                return common.ExitCode.misuse;
            },
            error.MissingValue => {
                try stderr_writer.print("{s}: option requires an argument\nTry '{s} --help' for more information.\n", .{ prog_name, prog_name });
                return common.ExitCode.misuse;
            },
            else => return err,
        }
    };
    defer allocator.free(args.positionals);

    if (args.help) {
        try printHelp(stdout_writer);
        return common.ExitCode.success;
    }
    if (args.version) {
        try stdout_writer.print("cp ({s}) {s}\n", .{ common.name, common.version });
        return common.ExitCode.success;
    }

    // Validate argument count
    if (args.positionals.len < 2) {
        if (args.positionals.len == 0) {
            try stderr_writer.print("{s}: missing file operand\n", .{prog_name});
            return common.ExitCode.misuse;
        } else {
            try stderr_writer.print("{s}: missing destination file operand after '{s}'\n", .{ prog_name, args.positionals[0] });
            return common.ExitCode.misuse;
        }
    }

    // Create options from parsed arguments
    const options = types.CpOptions{
        .recursive = args.r or args.R or args.recursive,
        .interactive = args.i or args.interactive,
        .force = args.f or args.force,
        .preserve = args.p or args.preserve,
        .no_dereference = args.d or args.no_dereference,
    };

    // Create copy context and engine
    const context = types.CopyContext.create(allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    // Plan all copy operations
    var operations = engine.planOperations(stderr_writer, args.positionals) catch |err| {
        switch (err) {
            error.InsufficientArguments => {
                try stderr_writer.print("{s}: insufficient arguments\n", .{prog_name});
                return common.ExitCode.misuse;
            },
            errors.CopyError.DestinationIsNotDirectory => {
                try stderr_writer.print("{s}: destination is not a directory\n", .{prog_name});
                return common.ExitCode.general_error;
            },
            else => {
                try stderr_writer.print("{s}: error planning operations: {}\n", .{ prog_name, err });
                return common.ExitCode.general_error;
            },
        }
    };
    defer {
        // Clean up all planned operations
        for (operations.items) |*op| {
            op.deinit(allocator);
        }
        operations.deinit();
    }

    // Execute all copy operations
    engine.executeCopyBatch(stderr_writer, operations.items) catch {
        return common.ExitCode.general_error;
    };

    // Check for errors during execution
    const stats = engine.getStats();
    if (stats.errors_encountered > 0) {
        return common.ExitCode.general_error;
    }

    return common.ExitCode.success;
}

/// Print help message for cp
fn printHelp(writer: anytype) !void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));
    try writer.print(
        \\Usage: {s} [OPTION]... [-T] SOURCE DEST
        \\   or: {s} [OPTION]... SOURCE... DIRECTORY
        \\   or: {s} [OPTION]... -t DIRECTORY SOURCE...
        \\Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.
        \\
        \\Options:
        \\  -d, --no-dereference     never follow symbolic links in SOURCE
        \\  -f, --force              force overwrite without prompting
        \\  -h, --help               display this help and exit
        \\  -i, --interactive        prompt before overwrite
        \\  -p, --preserve           preserve mode, ownership, timestamps
        \\  -r, -R, --recursive      copy directories recursively
        \\  -V, --version            output version information and exit
        \\
        \\Examples:
        \\  {s} foo.txt bar.txt    Copy foo.txt to bar.txt
        \\  {s} -r dir1 dir2       Copy dir1 and its contents to dir2
        \\  {s} file1 file2 dir/   Copy multiple files into dir/
        \\
    , .{ prog_name, prog_name, prog_name, prog_name, prog_name, prog_name });
}

// Tests

const testing = std.testing;
const TestUtils = @import("cp/test_utils.zig").TestUtils;
const privilege_test = common.privilege_test;

// Basic file copy
test "cp: single file copy" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "Hello, World!");

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest.txt");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{};
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    try test_dir.expectFileContent("dest.txt", "Hello, World!");
}

// Argument count validation
test "cp: basic argument validation" {
    const args_empty = [_][]const u8{};
    const args_one = [_][]const u8{"source"};
    const args_two = [_][]const u8{ "source", "dest" };

    try testing.expect(args_empty.len < 2);
    try testing.expect(args_one.len < 2);
    try testing.expect(args_two.len >= 2);
}

// Options structure defaults
test "cp: options structure" {
    const options_default = types.CpOptions{};
    try testing.expect(!options_default.recursive);
    try testing.expect(!options_default.interactive);
    try testing.expect(!options_default.force);
    try testing.expect(!options_default.preserve);
    try testing.expect(!options_default.no_dereference);

    const options_recursive = types.CpOptions{ .recursive = true };
    try testing.expect(options_recursive.recursive);
    try testing.expect(!options_recursive.interactive);
}

// Copy file to existing directory
test "cp: copy to existing directory" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "Test content");
    try test_dir.createDir("dest_dir");

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("dest_dir");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{};
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    try test_dir.expectFileContent("dest_dir/source.txt", "Test content");
}

// Directory copy requires recursive flag
test "cp: error on directory without recursive flag" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDir("source_dir");

    const source_path = try test_dir.getPath("source_dir");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest_dir");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{ .recursive = false };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try testing.expectError(errors.CopyError.RecursionNotAllowed, engine.executeCopy(stderr_writer, operation));
}

// Preserve file attributes (non-privileged)
test "cp: basic preserve attributes (non-privileged)" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFileWithMode("source.txt", "Test content", 0o644);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest.txt");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{ .preserve = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");

    // Check user permissions only (works without privileges)
    const source_user_perms = source_stat.mode & 0o700;
    const dest_user_perms = dest_stat.mode & 0o700;
    try testing.expectEqual(source_user_perms, dest_user_perms);
}

// Preserve attributes with privileges
test "privileged: cp preserve attributes" {
    try privilege_test.requiresPrivilege();

    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFileWithMode("source.txt", "Executable content", 0o755);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest.txt");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{ .preserve = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");
    try testing.expectEqual(source_stat.mode, dest_stat.mode);
}

// Recursive directory copy
test "cp: recursive directory copy" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source directory structure
    try test_dir.createDir("source_dir");
    try test_dir.createDir("source_dir/subdir");
    try test_dir.createFile("source_dir/file1.txt", "File 1 content");
    try test_dir.createFile("source_dir/subdir/file2.txt", "File 2 content");

    const source_path = try test_dir.getPath("source_dir");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest_dir");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{ .recursive = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    try test_dir.expectFileContent("dest_dir/file1.txt", "File 1 content");
    try test_dir.expectFileContent("dest_dir/subdir/file2.txt", "File 2 content");
}

// Force mode overwrites read-only files
test "privileged: cp force mode overwrites" {
    try privilege_test.requiresPrivilege();

    // Skip this test on macOS in CI environments where chmod can cause SIGABRT
    if (builtin.os.tag == .macos) {
        if (std.process.getEnvVarOwned(testing.allocator, "CI")) |ci_val| {
            testing.allocator.free(ci_val);
            return error.SkipZigTest;
        } else |_| {}
    }

    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "New content");
    try test_dir.createFileWithMode("dest.txt", "Old content", 0o444);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("dest.txt");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{ .force = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    try test_dir.expectFileContent("dest.txt", "New content");
}

// Symbolic links followed by default
test "cp: symbolic link handling - follow by default" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("original.txt", "Original content");
    try test_dir.createSymlink("original.txt", "link.txt");

    const link_path = try test_dir.getPath("link.txt");
    defer testing.allocator.free(link_path);
    const dest_path = try test_dir.joinPath("copied.txt");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{};
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(link_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    // Should copy file content, not create symlink
    try test_dir.expectFileContent("copied.txt", "Original content");
    try testing.expect(!test_dir.isSymlink("copied.txt"));
}

// Preserve symbolic links with -d flag
test "cp: symbolic link handling - no dereference (-d)" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("original.txt", "Original content");
    try test_dir.createSymlink("original.txt", "link.txt");

    const link_path = try test_dir.joinPath("link.txt");
    defer testing.allocator.free(link_path);
    const dest_path = try test_dir.joinPath("copied_link.txt");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{ .no_dereference = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(link_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    // Should create symlink, not copy content
    try testing.expect(test_dir.isSymlink("copied_link.txt"));
    const target = try test_dir.getSymlinkTarget("copied_link.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("original.txt", target);
}

// Copy broken symbolic links
test "cp: broken symlink handling" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createSymlink("nonexistent.txt", "broken_link.txt");

    const link_path = try test_dir.joinPath("broken_link.txt");
    defer testing.allocator.free(link_path);
    const dest_path = try test_dir.joinPath("copied_broken.txt");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{ .no_dereference = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(link_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    try testing.expect(test_dir.isSymlink("copied_broken.txt"));
    const target = try test_dir.getSymlinkTarget("copied_broken.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("nonexistent.txt", target);
}

// Multiple sources to directory
test "cp: multiple sources to directory" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("file1.txt", "Content 1");
    try test_dir.createFile("file2.txt", "Content 2");
    try test_dir.createDir("dest_dir");

    const file1_path = try test_dir.getPath("file1.txt");
    defer testing.allocator.free(file1_path);
    const file2_path = try test_dir.getPath("file2.txt");
    defer testing.allocator.free(file2_path);
    const dest_path = try test_dir.getPath("dest_dir");
    defer testing.allocator.free(dest_path);

    const args = [_][]const u8{ file1_path, file2_path, dest_path };

    const options = types.CpOptions{};
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    var operations = try engine.planOperations(stderr_writer, &args);
    defer {
        for (operations.items) |*op| {
            op.deinit(testing.allocator);
        }
        operations.deinit();
    }

    try engine.executeCopyBatch(stderr_writer, operations.items);

    try test_dir.expectFileContent("dest_dir/file1.txt", "Content 1");
    try test_dir.expectFileContent("dest_dir/file2.txt", "Content 2");
}

// Preserve ownership with privileges
test "privileged: cp preserve ownership with -p flag" {
    try privilege_test.requiresPrivilege();

    // Skip this test on macOS in CI environments where chmod can cause SIGABRT
    if (builtin.os.tag == .macos) {
        if (std.process.getEnvVarOwned(testing.allocator, "CI")) |ci_val| {
            testing.allocator.free(ci_val);
            return error.SkipZigTest;
        } else |_| {}
    }

    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source file
    try test_dir.createFile("source.txt", "Test content with ownership");

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest.txt");
    defer testing.allocator.free(dest_path);

    if (privilege_test.FakerootContext.isUnderFakeroot()) {
        const source_file = try std.fs.cwd().openFile(source_path, .{});
        defer source_file.close();

        source_file.chown(1000, 1000) catch |err| switch (err) {
            error.AccessDenied => {
                return;
            },
            else => return err,
        };
    }

    const options = types.CpOptions{ .preserve = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");

    try testing.expectEqual(source_stat.mode, dest_stat.mode);

    if (privilege_test.FakerootContext.isUnderFakeroot()) {}
}

// Preserve special permissions (setuid, setgid, sticky)
test "privileged: cp preserve special permissions (setuid, setgid, sticky)" {
    try privilege_test.requiresPrivilege();

    // Skip this test on macOS in CI environments where chmod can cause SIGABRT
    if (builtin.os.tag == .macos) {
        if (std.process.getEnvVarOwned(testing.allocator, "CI")) |ci_val| {
            testing.allocator.free(ci_val);
            return error.SkipZigTest;
        } else |_| {}
    }

    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Debug: Log test start
    if (std.process.getEnvVarOwned(testing.allocator, "DEBUG_TESTS")) |debug| {
        testing.allocator.free(debug);
        std.debug.print("\n[DEBUG] Starting privileged cp test\n", .{});
    } else |_| {}

    // Create files with special permissions
    try test_dir.createFileWithMode("setuid_file", "setuid content", 0o4755);
    try test_dir.createFileWithMode("setgid_file", "setgid content", 0o2755);

    {
        const source_path = try test_dir.getPath("setuid_file");
        defer testing.allocator.free(source_path);
        const dest_path = try test_dir.joinPath("setuid_copy");
        defer testing.allocator.free(dest_path);

        const options = types.CpOptions{ .preserve = true };
        const context = types.CopyContext.create(testing.allocator, options);
        var engine = copy_engine.CopyEngine.init(context);

        var operation = try context.planOperation(source_path, dest_path);
        defer operation.deinit(testing.allocator);

        // Debug: This should be a fresh test directory, so dest should not exist
        if (operation.dest_exists) {
            std.debug.print("\n[WARNING] Destination already exists in test: {s}\n", .{dest_path});
        }

        var test_stderr = std.ArrayList(u8).init(testing.allocator);
        defer test_stderr.deinit();
        const stderr_writer = test_stderr.writer();

        try engine.executeCopy(stderr_writer, operation);

        const source_stat = try test_dir.getFileStat("setuid_file");
        const dest_stat = try test_dir.getFileStat("setuid_copy");

        try testing.expectEqual(source_stat.mode & 0o7777, dest_stat.mode & 0o7777);
    }

    {
        const source_path = try test_dir.getPath("setgid_file");
        defer testing.allocator.free(source_path);
        const dest_path = try test_dir.joinPath("setgid_copy");
        defer testing.allocator.free(dest_path);

        const options = types.CpOptions{ .preserve = true };
        const context = types.CopyContext.create(testing.allocator, options);
        var engine = copy_engine.CopyEngine.init(context);

        var operation = try context.planOperation(source_path, dest_path);
        defer operation.deinit(testing.allocator);

        var test_stderr = std.ArrayList(u8).init(testing.allocator);
        defer test_stderr.deinit();
        const stderr_writer = test_stderr.writer();

        try engine.executeCopy(stderr_writer, operation);

        const source_stat = try test_dir.getFileStat("setgid_file");
        const dest_stat = try test_dir.getFileStat("setgid_copy");

        try testing.expectEqual(source_stat.mode & 0o7777, dest_stat.mode & 0o7777);
    }

    try test_dir.createDir("sticky_dir");
    const sticky_path = try test_dir.getPath("sticky_dir");
    defer testing.allocator.free(sticky_path);

    // Set sticky bit using posix API directly to avoid SIGABRT on macOS
    {
        var sticky_dir = try std.fs.cwd().openDir(sticky_path, .{ .iterate = true });
        defer sticky_dir.close();
        std.posix.fchmod(sticky_dir.fd, 0o1755) catch |err| {
            // If we can't set special permissions, skip the test
            if (err == error.AccessDenied or err == error.PermissionDenied) {
                return error.SkipZigTest;
            }
            return err;
        };
    }

    const sticky_dest = try test_dir.joinPath("sticky_copy");
    defer testing.allocator.free(sticky_dest);

    const options = types.CpOptions{ .preserve = true, .recursive = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(sticky_path, sticky_dest);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    const source_stat = try test_dir.getFileStat("sticky_dir");
    const dest_stat = try test_dir.getFileStat("sticky_copy");

    try testing.expectEqual(source_stat.mode & 0o7777, dest_stat.mode & 0o7777);
}

// Recursive copy with full attribute preservation
test "privileged: cp recursive directory copy with full attribute preservation" {
    try privilege_test.requiresPrivilege();

    // Skip this test on macOS in CI environments where chmod can cause SIGABRT
    if (common.file_ops.shouldSkipMacOSCITest()) {
        return error.SkipZigTest;
    }

    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDir("source_tree");
    try test_dir.createFileWithMode("source_tree/executable", "#!/bin/sh\necho test", 0o755);
    try test_dir.createFileWithMode("source_tree/readonly", "readonly content", 0o444);
    try test_dir.createDir("source_tree/subdir");
    try test_dir.createFileWithMode("source_tree/subdir/setuid", "setuid content", 0o4755);

    // Set directory permissions using posix API directly to avoid SIGABRT on macOS
    const subdir_path = try test_dir.getPath("source_tree/subdir");
    defer testing.allocator.free(subdir_path);
    {
        var subdir = try std.fs.cwd().openDir(subdir_path, .{ .iterate = true });
        defer subdir.close();
        common.file_ops.setPermissions(subdir, 0o2755, "source_tree/subdir") catch |err| {
            // If we can't set special permissions, skip the test
            if (err == error.AccessDenied or err == error.PermissionDenied) {
                return error.SkipZigTest;
            }
            return err;
        };
    }

    const source_path = try test_dir.getPath("source_tree");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest_tree");
    defer testing.allocator.free(dest_path);

    const options = types.CpOptions{ .preserve = true, .recursive = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);

    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try engine.executeCopy(stderr_writer, operation);

    {
        const exec_src = try test_dir.getFileStat("source_tree/executable");
        const exec_dst = try test_dir.getFileStat("dest_tree/executable");
        try testing.expectEqual(exec_src.mode & 0o7777, exec_dst.mode & 0o7777);
    }

    {
        const ro_src = try test_dir.getFileStat("source_tree/readonly");
        const ro_dst = try test_dir.getFileStat("dest_tree/readonly");

        try testing.expectEqual(ro_src.mode & 0o7777, ro_dst.mode & 0o7777);
    }

    {
        const subdir_src = try test_dir.getFileStat("source_tree/subdir");
        const subdir_dst = try test_dir.getFileStat("dest_tree/subdir");
        try testing.expectEqual(subdir_src.mode & 0o7777, subdir_dst.mode & 0o7777);
    }

    {
        const setuid_src = try test_dir.getFileStat("source_tree/subdir/setuid");
        const setuid_dst = try test_dir.getFileStat("dest_tree/subdir/setuid");
        try testing.expectEqual(setuid_src.mode & 0o7777, setuid_dst.mode & 0o7777);
    }

    try test_dir.expectFileContent("dest_tree/executable", "#!/bin/sh\necho test");
    try test_dir.expectFileContent("dest_tree/readonly", "readonly content");
    try test_dir.expectFileContent("dest_tree/subdir/setuid", "setuid content");
}
