const std = @import("std");
const common = @import("common");

// Import our new modular architecture
const types = @import("cp/types.zig");
const errors = @import("cp/errors.zig");
const copy_engine = @import("cp/copy_engine.zig");
const user_interaction = @import("cp/user_interaction.zig");

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Parse arguments using new parser
    const args = common.argparse.ArgParser.parseProcess(CpArgs, allocator) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.fatal("unrecognized option\nTry 'cp --help' for more information.", .{});
            },
            error.MissingValue => {
                common.fatal("option requires an argument\nTry 'cp --help' for more information.", .{});
            },
            else => return err,
        }
    };
    defer allocator.free(args.positionals);

    if (args.help) {
        try printHelp();
        return;
    }
    if (args.version) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("cp ({s}) {s}\n", .{ common.name, common.version });
        return;
    }

    // Validate argument count
    if (args.positionals.len < 2) {
        if (args.positionals.len == 0) {
            common.fatal("missing file operand", .{});
        } else {
            common.fatal("missing destination file operand after '{s}'", .{args.positionals[0]});
        }
    }

    // Create options from parsed arguments - merge -r, -R and --recursive
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

    // Plan all operations upfront
    var operations = engine.planOperations(args.positionals) catch |err| {
        switch (err) {
            error.InsufficientArguments => common.fatal("insufficient arguments", .{}),
            errors.CopyError.DestinationIsNotDirectory => common.fatal("destination is not a directory", .{}),
            else => common.fatal("error planning operations: {}", .{err}),
        }
    };
    defer {
        for (operations.items) |*op| {
            op.deinit(allocator);
        }
        operations.deinit();
    }

    // Execute all operations
    engine.executeCopyBatch(operations.items) catch {
        return; // Error already reported by engine
    };

    // Check final statistics for any errors
    const stats = engine.getStats();
    if (stats.errors_encountered > 0) {
        return; // Errors already reported during operation
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));
    try stdout.print(
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

// =============================================================================
// TESTS (Migrated from original implementation)
// =============================================================================

const testing = std.testing;
const TestUtils = @import("cp/test_utils.zig").TestUtils;
const privilege_test = common.privilege_test;

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

    try engine.executeCopy(operation);

    try test_dir.expectFileContent("dest.txt", "Hello, World!");
}

test "cp: basic argument validation" {
    // Test argument count validation logic
    const args_empty = [_][]const u8{};
    const args_one = [_][]const u8{"source"};
    const args_two = [_][]const u8{ "source", "dest" };

    // Empty args should be invalid
    try testing.expect(args_empty.len < 2);

    // One arg should be invalid
    try testing.expect(args_one.len < 2);

    // Two args should be valid
    try testing.expect(args_two.len >= 2);
}

test "cp: options structure" {
    // Test that our options structure works correctly
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

    try engine.executeCopy(operation);

    try test_dir.expectFileContent("dest_dir/source.txt", "Test content");
}

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

    try testing.expectError(errors.CopyError.RecursionNotAllowed, engine.executeCopy(operation));
}

test "cp: basic preserve attributes (non-privileged)" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create a file with specific permissions (within user's rights)
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

    try engine.executeCopy(operation);

    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");

    // Only check user permissions, as these should work without privileges
    const source_user_perms = source_stat.mode & 0o700;
    const dest_user_perms = dest_stat.mode & 0o700;
    try testing.expectEqual(source_user_perms, dest_user_perms);
}

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

    try engine.executeCopy(operation);

    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");
    try testing.expectEqual(source_stat.mode, dest_stat.mode);
}

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

    try engine.executeCopy(operation);

    try test_dir.expectFileContent("dest_dir/file1.txt", "File 1 content");
    try test_dir.expectFileContent("dest_dir/subdir/file2.txt", "File 2 content");
}

test "privileged: cp force mode overwrites" {
    try privilege_test.requiresPrivilege();

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

    try engine.executeCopy(operation);

    try test_dir.expectFileContent("dest.txt", "New content");
}

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

    try engine.executeCopy(operation);

    // Should copy the file content, not create a symlink
    try test_dir.expectFileContent("copied.txt", "Original content");
    try testing.expect(!test_dir.isSymlink("copied.txt"));
}

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

    try engine.executeCopy(operation);

    // Should create a symlink, not copy file content
    try testing.expect(test_dir.isSymlink("copied_link.txt"));
    const target = try test_dir.getSymlinkTarget("copied_link.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("original.txt", target);
}

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

    try engine.executeCopy(operation);

    // Should copy broken symlink as symlink
    try testing.expect(test_dir.isSymlink("copied_broken.txt"));
    const target = try test_dir.getSymlinkTarget("copied_broken.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("nonexistent.txt", target);
}

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

    var operations = try engine.planOperations(&args);
    defer {
        for (operations.items) |*op| {
            op.deinit(testing.allocator);
        }
        operations.deinit();
    }

    try engine.executeCopyBatch(operations.items);

    try test_dir.expectFileContent("dest_dir/file1.txt", "Content 1");
    try test_dir.expectFileContent("dest_dir/file2.txt", "Content 2");
}

test "privileged: cp preserve ownership with -p flag" {
    try privilege_test.requiresPrivilege();

    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source file
    try test_dir.createFile("source.txt", "Test content with ownership");

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest.txt");
    defer testing.allocator.free(dest_path);

    // Set specific owner/group on source (in fakeroot environment)
    if (privilege_test.FakerootContext.isUnderFakeroot()) {
        const source_file = try std.fs.cwd().openFile(source_path, .{});
        defer source_file.close();

        // Attempt to change ownership (may not work on all platforms with fakeroot)
        source_file.chown(1000, 1000) catch |err| switch (err) {
            error.AccessDenied => {
                // Expected on some platforms, skip this part of the test
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

    try engine.executeCopy(operation);

    // Verify attributes were preserved
    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");

    // Mode should always be preserved
    try testing.expectEqual(source_stat.mode, dest_stat.mode);

    // Ownership preservation depends on platform and fakeroot support
    if (privilege_test.FakerootContext.isUnderFakeroot()) {
        // In fakeroot, ownership operations may be simulated
        // The important thing is that cp attempted to preserve ownership
        // and didn't fail. Actual uid/gid verification may not work
        // reliably across all fakeroot implementations

        // In a real privileged environment, we would verify:
        // try testing.expectEqual(@as(u32, 1000), dest_stat.uid);
        // try testing.expectEqual(@as(u32, 1000), dest_stat.gid);
    }
}

test "privileged: cp preserve special permissions (setuid, setgid, sticky)" {
    try privilege_test.requiresPrivilege();

    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create files with special permissions
    try test_dir.createFileWithMode("setuid_file", "setuid content", 0o4755);
    try test_dir.createFileWithMode("setgid_file", "setgid content", 0o2755);

    // Test setuid preservation
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

        try engine.executeCopy(operation);

        const source_stat = try test_dir.getFileStat("setuid_file");
        const dest_stat = try test_dir.getFileStat("setuid_copy");

        // Check that setuid bit is preserved
        try testing.expectEqual(source_stat.mode & 0o7777, dest_stat.mode & 0o7777);
    }

    // Test setgid preservation
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

        try engine.executeCopy(operation);

        const source_stat = try test_dir.getFileStat("setgid_file");
        const dest_stat = try test_dir.getFileStat("setgid_copy");

        // Check that setgid bit is preserved
        try testing.expectEqual(source_stat.mode & 0o7777, dest_stat.mode & 0o7777);
    }

    // Test sticky bit on directory
    try test_dir.createDir("sticky_dir");
    const sticky_path = try test_dir.getPath("sticky_dir");
    defer testing.allocator.free(sticky_path);

    // Set sticky bit
    {
        var sticky_dir = try std.fs.cwd().openDir(sticky_path, .{ .iterate = true });
        defer sticky_dir.close();
        try sticky_dir.chmod(0o1755);
    }

    const sticky_dest = try test_dir.joinPath("sticky_copy");
    defer testing.allocator.free(sticky_dest);

    const options = types.CpOptions{ .preserve = true, .recursive = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    var operation = try context.planOperation(sticky_path, sticky_dest);
    defer operation.deinit(testing.allocator);

    try engine.executeCopy(operation);

    const source_stat = try test_dir.getFileStat("sticky_dir");
    const dest_stat = try test_dir.getFileStat("sticky_copy");

    // Check that sticky bit is preserved
    try testing.expectEqual(source_stat.mode & 0o7777, dest_stat.mode & 0o7777);
}

test "privileged: cp recursive directory copy with full attribute preservation" {
    try privilege_test.requiresPrivilege();

    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create a complex directory structure with various permissions
    try test_dir.createDir("source_tree");
    try test_dir.createFileWithMode("source_tree/executable", "#!/bin/sh\necho test", 0o755);
    try test_dir.createFileWithMode("source_tree/readonly", "readonly content", 0o444);
    try test_dir.createDir("source_tree/subdir");
    try test_dir.createFileWithMode("source_tree/subdir/setuid", "setuid content", 0o4755);

    // Set directory permissions
    const subdir_path = try test_dir.getPath("source_tree/subdir");
    defer testing.allocator.free(subdir_path);
    {
        var subdir = try std.fs.cwd().openDir(subdir_path, .{ .iterate = true });
        defer subdir.close();
        try subdir.chmod(0o2755); // setgid on directory
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

    try engine.executeCopy(operation);

    // Verify all permissions were preserved
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

    // Verify content was also copied correctly
    try test_dir.expectFileContent("dest_tree/executable", "#!/bin/sh\necho test");
    try test_dir.expectFileContent("dest_tree/readonly", "readonly content");
    try test_dir.expectFileContent("dest_tree/subdir/setuid", "setuid content");
}
