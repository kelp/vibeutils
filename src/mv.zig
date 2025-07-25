const std = @import("std");
const testing = std.testing;
const clap = @import("clap");
const common = @import("common/lib.zig");

const params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\-V, --version           Output version information and exit.
    \\-i, --interactive       Prompt before overwrite.
    \\-f, --force             Force overwrite without prompting.
    \\-v, --verbose           Explain what is being done.
    \\-n, --no-clobber       Do not overwrite an existing file.
    \\<str>...                Source and destination paths.
    \\
);

// Test helpers
const TestDir = struct {
    tmp_dir: testing.TmpDir,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestDir {
        return .{
            .tmp_dir = testing.tmpDir(.{}),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestDir) void {
        self.tmp_dir.cleanup();
    }

    pub fn createFile(self: *TestDir, name: []const u8, content: []const u8) !void {
        const file = try self.tmp_dir.dir.createFile(name, .{});
        defer file.close();
        try file.writeAll(content);
    }

    pub fn fileExists(self: *TestDir, name: []const u8) bool {
        self.tmp_dir.dir.access(name, .{}) catch return false;
        return true;
    }

    pub fn readFile(self: *TestDir, name: []const u8) ![]u8 {
        return try self.tmp_dir.dir.readFileAlloc(self.allocator, name, 1024 * 1024);
    }

    pub fn getPath(self: *TestDir, name: []const u8) ![]u8 {
        return try self.tmp_dir.dir.realpathAlloc(self.allocator, name);
    }
};

test "mv: basic test" {
    // Simple test to verify the module compiles and basic types work
    const options = MoveOptions{};
    try testing.expect(!options.interactive);
    try testing.expect(!options.force);
    try testing.expect(!options.verbose);
    try testing.expect(!options.no_clobber);
}

test "mv: file rename in same directory" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source file
    try test_dir.createFile("old.txt", "Hello, World!");

    // Get full paths to source and destination  
    const old_path = try test_dir.getPath("old.txt");
    defer testing.allocator.free(old_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const new_path = try std.fmt.allocPrint(testing.allocator, "{s}/new.txt", .{base_path});
    defer testing.allocator.free(new_path);

    // Run mv
    try moveFile(testing.allocator, old_path, new_path, .{});

    // Verify old file is gone
    try testing.expect(!test_dir.fileExists("old.txt"));

    // Verify new file exists with same content
    try testing.expect(test_dir.fileExists("new.txt"));
    const content = try test_dir.readFile("new.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Hello, World!", content);
}

test "mv: move to different directory" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source file and destination directory
    try test_dir.createFile("source.txt", "Move me!");
    try test_dir.tmp_dir.dir.makeDir("subdir");

    // Get paths
    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath("subdir");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/source.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    // Run mv
    try moveFile(testing.allocator, source_path, dest_path, .{});

    // Verify original is gone
    try testing.expect(!test_dir.fileExists("source.txt"));

    // Verify file exists in new location
    const moved_file = try test_dir.tmp_dir.dir.openFile("subdir/source.txt", .{});
    moved_file.close();
    
    // Verify content is preserved
    const content = try test_dir.tmp_dir.dir.readFileAlloc(testing.allocator, "subdir/source.txt", 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Move me!", content);
}

test "mv: directory move" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source directory with a file inside
    try test_dir.tmp_dir.dir.makeDir("source_dir");
    const source_file = try test_dir.tmp_dir.dir.createFile("source_dir/file.txt", .{});
    try source_file.writeAll("Inside directory");
    source_file.close();

    // Get paths
    const source_path = try test_dir.getPath("source_dir");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getPath(".");
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest_dir", .{base_path});
    defer testing.allocator.free(dest_path);

    // Run mv
    try moveFile(testing.allocator, source_path, dest_path, .{});

    // Verify original directory is gone
    test_dir.tmp_dir.dir.access("source_dir", .{}) catch |err| {
        try testing.expect(err == error.FileNotFound);
    };

    // Verify new directory exists with file intact
    const moved_file = try test_dir.tmp_dir.dir.openFile("dest_dir/file.txt", .{});
    defer moved_file.close();
    
    // Verify content is preserved
    const content = try test_dir.tmp_dir.dir.readFileAlloc(testing.allocator, "dest_dir/file.txt", 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Inside directory", content);
}

test "mv: force mode overwrites existing file" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source and existing destination
    try test_dir.createFile("source.txt", "New content");
    try test_dir.createFile("dest.txt", "Existing content");

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("dest.txt");
    defer testing.allocator.free(dest_path);

    // With force mode, should overwrite without error
    const options = MoveOptions{ .force = true };
    try moveFile(testing.allocator, source_path, dest_path, options);

    // Verify source is gone and dest has new content
    try testing.expect(!test_dir.fileExists("source.txt"));
    const content = try test_dir.readFile("dest.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("New content", content);
}

test "mv: no-clobber mode preserves existing file" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source and existing destination
    try test_dir.createFile("source.txt", "New content");
    try test_dir.createFile("dest.txt", "Existing content");

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("dest.txt");
    defer testing.allocator.free(dest_path);

    // With no-clobber mode, should not overwrite
    const options = MoveOptions{ .no_clobber = true };
    try moveFile(testing.allocator, source_path, dest_path, options);

    // Verify source still exists and dest is unchanged
    try testing.expect(test_dir.fileExists("source.txt"));
    const content = try test_dir.readFile("dest.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Existing content", content);
}

// Cross-filesystem move helper using cp functionality
fn crossFilesystemMove(allocator: std.mem.Allocator, source: []const u8, dest: []const u8, options: MoveOptions) !void {
    // Import cp modules for cross-filesystem copy
    const cp_types = @import("cp/types.zig");
    const cp_engine = @import("cp/copy_engine.zig");
    
    // Create cp options from mv options
    const cp_options = cp_types.CpOptions{
        .recursive = true, // Always recursive for directories
        .preserve = true,  // Preserve attributes
        .force = options.force,
        .interactive = options.interactive,
    };
    
    // Use cp's copy engine
    const cp_context = cp_types.CopyContext.create(allocator, cp_options);
    var engine = cp_engine.CopyEngine.init(cp_context);
    
    // Plan and execute the copy
    var operation = try cp_context.planOperation(source, dest);
    defer operation.deinit(allocator);
    
    try engine.executeCopy(operation);
    
    // If copy succeeded, remove the source
    const source_stat = try std.fs.cwd().statFile(source);
    if (source_stat.kind == .directory) {
        try std.fs.cwd().deleteTree(source);
    } else {
        try std.fs.cwd().deleteFile(source);
    }
}

// Check if user wants to proceed with overwrite
fn promptOverwrite(dest: []const u8) !bool {
    const stderr = std.io.getStdErr().writer();
    const stdin = std.io.getStdIn().reader();
    
    try stderr.print("mv: overwrite '{s}'? ", .{dest});
    
    var buf: [16]u8 = undefined;
    if (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        return trimmed.len > 0 and (trimmed[0] == 'y' or trimmed[0] == 'Y');
    }
    return false;
}

// Main move function
fn moveFile(allocator: std.mem.Allocator, source: []const u8, dest: []const u8, options: MoveOptions) !void {
    // Check if destination exists
    const dest_exists = blk: {
        std.fs.cwd().access(dest, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };

    if (dest_exists) {
        // Handle existing destination based on options
        if (options.no_clobber) {
            return; // Silently skip
        }
        
        if (options.interactive and !options.force) {
            if (!try promptOverwrite(dest)) {
                return; // User chose not to overwrite
            }
        }
    }

    // Try atomic rename first
    std.posix.rename(source, dest) catch |err| switch (err) {
        error.RenameAcrossMountPoints => {
            // Fall back to copy + remove
            try crossFilesystemMove(allocator, source, dest, options);
        },
        else => return err,
    };
}

const MoveOptions = struct {
    interactive: bool = false,
    force: bool = false,
    verbose: bool = false,
    no_clobber: bool = false,
};

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
        const stderr = std.io.getStdErr().writer();
        try stderr.print("mv: missing file operand\n", .{});
        try stderr.print("Try 'mv --help' for more information.\n", .{});
        std.process.exit(@intFromEnum(common.ExitCode.misuse));
    }

    const options = MoveOptions{
        .interactive = res.args.interactive != 0,
        .force = res.args.force != 0,
        .verbose = res.args.verbose != 0,
        .no_clobber = res.args.@"no-clobber" != 0,
    };

    // Handle multiple sources case
    if (args.len > 2) {
        // Multiple sources - destination must be a directory
        const dest = args[args.len - 1];
        const dest_stat = std.fs.cwd().statFile(dest) catch |err| switch (err) {
            error.FileNotFound => {
                const stderr = std.io.getStdErr().writer();
                try stderr.print("mv: target '{s}' is not a directory\n", .{dest});
                std.process.exit(@intFromEnum(common.ExitCode.general_error));
            },
            else => return err,
        };

        if (dest_stat.kind != .directory) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("mv: target '{s}' is not a directory\n", .{dest});
            std.process.exit(@intFromEnum(common.ExitCode.general_error));
        }

        // Move each source to destination directory
        for (args[0..args.len - 1]) |source| {
            const basename = std.fs.path.basename(source);
            const full_dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename });
            defer allocator.free(full_dest);

            moveFile(allocator, source, full_dest, options) catch |err| {
                const stderr = std.io.getStdErr().writer();
                try stderr.print("mv: cannot move '{s}' to '{s}': {}\n", .{ source, full_dest, err });
                std.process.exit(@intFromEnum(common.ExitCode.general_error));
            };

            if (options.verbose) {
                const stdout = std.io.getStdOut().writer();
                try stdout.print("'{s}' -> '{s}'\n", .{ source, full_dest });
            }
        }
    } else {
        // Single source
        const source = args[0];
        const dest = args[1];

        moveFile(allocator, source, dest, options) catch |err| {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("mv: cannot move '{s}' to '{s}': {}\n", .{ source, dest, err });
            std.process.exit(@intFromEnum(common.ExitCode.general_error));
        };

        if (options.verbose) {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("'{s}' -> '{s}'\n", .{ source, dest });
        }
    }
}