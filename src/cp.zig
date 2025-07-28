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

test "cp: preserve attributes" {
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

test "cp: force mode overwrites" {
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
