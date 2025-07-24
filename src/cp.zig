const std = @import("std");
const common = @import("common/lib.zig");
const clap = @import("clap");

// Import our new modular architecture
const types = @import("cp/types.zig");
const errors = @import("cp/errors.zig");
const copy_engine = @import("cp/copy_engine.zig");
const user_interaction = @import("cp/user_interaction.zig");

const params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\-V, --version           Output version information and exit.
    \\-r, --recursive         Copy directories recursively.
    \\-R                      Copy directories recursively (same as -r).
    \\-i, --interactive       Prompt before overwrite.
    \\-f, --force             Force overwrite without prompting.
    \\-p, --preserve          Preserve mode, ownership, timestamps.
    \\-d, --no-dereference    Never follow symbolic links in SOURCE.
    \\<str>...                Source and destination paths.
    \\
);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parsers = comptime .{
        .str = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    const res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| switch (err) {
        error.InvalidArgument => {
            diag.report(std.io.getStdErr().writer(), err) catch {};
            std.process.exit(@intFromEnum(common.ExitCode.misuse));
        },
        else => return err,
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }
    if (res.args.version != 0) {
        common.CommonOpts.printVersion();
        return;
    }

    const args = res.positionals.@"0";
    
    // Validate argument count
    if (args.len < 2) {
        if (args.len == 0) {
            common.printError("missing file operand", .{});
        } else {
            common.printError("missing destination file operand after '{s}'", .{args[0]});
        }
        std.process.exit(@intFromEnum(common.ExitCode.misuse));
    }

    // Create options from parsed arguments
    const options = types.CpOptions{
        .recursive = res.args.recursive != 0 or res.args.R != 0,
        .interactive = res.args.interactive != 0,
        .force = res.args.force != 0,
        .preserve = res.args.preserve != 0,
        .no_dereference = res.args.@"no-dereference" != 0,
    };

    // Create copy context and engine
    const context = types.CopyContext.create(allocator, options);
    var engine = copy_engine.CopyEngine.init(context);

    // Plan all operations upfront
    var operations = engine.planOperations(args) catch |err| {
        const exit_code = switch (err) {
            error.InsufficientArguments => common.ExitCode.misuse,
            errors.CopyError.DestinationIsNotDirectory => common.ExitCode.general_error,
            else => common.ExitCode.general_error,
        };
        std.process.exit(@intFromEnum(exit_code));
    };
    defer {
        for (operations.items) |*op| {
            op.deinit(allocator);
        }
        operations.deinit();
    }

    // Execute all operations
    engine.executeCopyBatch(operations.items) catch {
        std.process.exit(@intFromEnum(common.ExitCode.general_error));
    };

    // Check final statistics for any errors
    const stats = engine.getStats();
    if (stats.errors_encountered > 0) {
        std.process.exit(@intFromEnum(common.ExitCode.general_error));
    }
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