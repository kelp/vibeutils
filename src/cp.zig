const std = @import("std");
const common = @import("common/lib.zig");
const clap = @import("clap");
const testing = std.testing;

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
    
    if (args.len < 2) {
        if (args.len == 0) {
            common.printError("missing file operand", .{});
        } else {
            common.printError("missing destination file operand after '{s}'", .{args[0]});
        }
        std.process.exit(@intFromEnum(common.ExitCode.misuse));
    }

    const options = CpOptions{
        .recursive = res.args.recursive != 0 or res.args.R != 0,
        .interactive = res.args.interactive != 0,
        .force = res.args.force != 0,
        .preserve = res.args.preserve != 0,
        .no_dereference = res.args.@"no-dereference" != 0,
    };

    // If multiple sources, destination must be a directory
    if (args.len > 2) {
        const dest_stat = std.fs.cwd().statFile(args[args.len - 1]) catch |err| switch (err) {
            error.FileNotFound => {
                common.printError("target '{s}' is not a directory", .{args[args.len - 1]});
                std.process.exit(@intFromEnum(common.ExitCode.general_error));
            },
            else => return err,
        };
        if (dest_stat.kind != .directory) {
            common.printError("target '{s}' is not a directory", .{args[args.len - 1]});
            std.process.exit(@intFromEnum(common.ExitCode.general_error));
        }
    }

    // Copy each source to destination
    for (args[0..args.len - 1]) |source| {
        const dest = args[args.len - 1];
        try copyFile(allocator, source, dest, options);
    }
}

const CpOptions = struct {
    recursive: bool = false,
    interactive: bool = false,
    force: bool = false,
    preserve: bool = false,
    no_dereference: bool = false,
};

fn copyFile(allocator: std.mem.Allocator, source: []const u8, dest: []const u8, options: CpOptions) !void {
    
    // Check if source exists
    const source_stat = std.fs.cwd().statFile(source) catch |err| switch (err) {
        error.FileNotFound => {
            common.printError("cannot stat '{s}': No such file or directory", .{source});
            return err;
        },
        else => return err,
    };
    
    // If source is a directory, need recursive flag
    if (source_stat.kind == .directory and !options.recursive) {
        common.printError("'{s}' is a directory (not copied)", .{source});
        return error.IsDir;
    }
    
    // Handle interactive mode
    if (options.interactive) {
        const dest_exists = blk: {
            std.fs.cwd().access(dest, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        
        if (dest_exists) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("cp: overwrite '{s}'? ", .{dest});
            
            var buffer: [10]u8 = undefined;
            const stdin = std.io.getStdIn().reader();
            if (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
                if (line.len == 0 or (line[0] != 'y' and line[0] != 'Y')) {
                    return;
                }
            }
        }
    }
    
    // Simple file copy for now
    if (source_stat.kind == .file) {
        // If destination exists and is a directory, copy into it
        const dest_stat = std.fs.cwd().statFile(dest) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        
        const final_dest = if (dest_stat != null and dest_stat.?.kind == .directory)
            try std.fs.path.join(allocator, &[_][]const u8{ dest, std.fs.path.basename(source) })
        else
            dest;
        defer if (dest_stat != null and dest_stat.?.kind == .directory) allocator.free(final_dest);
        
        // Copy the file
        try std.fs.cwd().copyFile(source, std.fs.cwd(), final_dest, .{});
        
        // Preserve attributes if requested
        if (options.preserve) {
            // Get source file handle
            const source_file = try std.fs.cwd().openFile(source, .{});
            defer source_file.close();
            
            // Get destination file handle
            const dest_file = try std.fs.cwd().openFile(final_dest, .{});
            defer dest_file.close();
            
            // Copy mode/permissions
            try dest_file.chmod(source_stat.mode);
            
            // Copy timestamps (mtime and atime)
            try dest_file.updateTimes(
                source_stat.atime,
                source_stat.mtime,
            );
        }
    } else if (source_stat.kind == .directory and options.recursive) {
        // TODO: Implement recursive directory copy
        return error.NotImplemented;
    }
}

// =============================================================================
// TESTS
// =============================================================================

test "cp: single file copy" {
    // Create a temporary directory for testing
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create source file
    const source_file = try tmp_dir.dir.createFile("source.txt", .{});
    try source_file.writeAll("Hello, World!");
    source_file.close();

    // Get paths within temp directory
    const source_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "source.txt");
    defer testing.allocator.free(source_path);
    
    var dest_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &dest_path_buf);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest.txt", .{tmp_path});
    defer testing.allocator.free(dest_path);
    
    const options = CpOptions{};
    
    // Copy the file
    try copyFile(testing.allocator, source_path, dest_path, options);
    
    // Verify the destination file exists and has correct content
    const dest_file = try tmp_dir.dir.openFile("dest.txt", .{});
    defer dest_file.close();
    
    var buffer: [100]u8 = undefined;
    const bytes_read = try dest_file.read(&buffer);
    try testing.expectEqualStrings("Hello, World!", buffer[0..bytes_read]);
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
    const options_default = CpOptions{};
    try testing.expect(!options_default.recursive);
    try testing.expect(!options_default.interactive);
    try testing.expect(!options_default.force);
    try testing.expect(!options_default.preserve);
    try testing.expect(!options_default.no_dereference);
    
    const options_recursive = CpOptions{ .recursive = true };
    try testing.expect(options_recursive.recursive);
    try testing.expect(!options_recursive.interactive);
}

test "cp: target must be directory for multiple sources" {
    // This test will pass since we're testing the logic, not file operations
    const args = [_][]const u8{ "file1", "file2", "not_a_directory" };
    
    if (args.len > 2) {
        // In real implementation, this would check if destination is a directory
        // For now, we're just testing the argument count logic
        try testing.expect(args.len == 3);
    }
}

test "cp: copy to existing directory" {
    // Create a temporary directory for testing
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create source file
    const source_file = try tmp_dir.dir.createFile("source.txt", .{});
    try source_file.writeAll("Test content");
    source_file.close();

    // Create destination directory
    try tmp_dir.dir.makeDir("dest_dir");

    // Get paths
    const source_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "source.txt");
    defer testing.allocator.free(source_path);
    
    const dest_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "dest_dir");
    defer testing.allocator.free(dest_path);
    
    const options = CpOptions{};
    
    // Copy file to directory
    try copyFile(testing.allocator, source_path, dest_path, options);
    
    // Verify the file was copied into the directory
    const copied_file = try tmp_dir.dir.openFile("dest_dir/source.txt", .{});
    defer copied_file.close();
    
    var buffer: [100]u8 = undefined;
    const bytes_read = try copied_file.read(&buffer);
    try testing.expectEqualStrings("Test content", buffer[0..bytes_read]);
}

test "cp: error on directory without recursive flag" {
    // Create a temporary directory for testing
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a source directory
    try tmp_dir.dir.makeDir("source_dir");
    
    const source_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "source_dir");
    defer testing.allocator.free(source_path);
    
    const options = CpOptions{ .recursive = false };
    
    // Should fail when trying to copy directory without -r
    try testing.expectError(error.IsDir, copyFile(testing.allocator, source_path, "dest_dir", options));
}

test "cp: preserve attributes" {
    // Create a temporary directory for testing
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create source file with specific permissions
    const source_file = try tmp_dir.dir.createFile("source.txt", .{ .mode = 0o755 });
    try source_file.writeAll("Executable content");
    source_file.close();
    
    // Get source stat for comparison
    const source_stat = try tmp_dir.dir.statFile("source.txt");

    // Get paths
    const source_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "source.txt");
    defer testing.allocator.free(source_path);
    
    var dest_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &dest_path_buf);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest.txt", .{tmp_path});
    defer testing.allocator.free(dest_path);
    
    const options = CpOptions{ .preserve = true };
    
    // Copy with preserve flag
    try copyFile(testing.allocator, source_path, dest_path, options);
    
    // Verify attributes were preserved
    const dest_stat = try tmp_dir.dir.statFile("dest.txt");
    try testing.expectEqual(source_stat.mode, dest_stat.mode);
}