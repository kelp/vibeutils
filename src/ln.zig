const std = @import("std");
const common = @import("common");
const testing = std.testing;

const LnArgs = struct {
    help: bool = false,
    version: bool = false,
    force: bool = false,
    interactive: bool = false,
    logical: bool = false,
    no_dereference: bool = false,
    physical: bool = false,
    relative: bool = false,
    symbolic: bool = false,
    target_directory: ?[]const u8 = null,
    no_target_directory: bool = false,
    verbose: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .force = .{ .short = 'f', .desc = "Remove existing destination files" },
        .interactive = .{ .short = 'i', .desc = "Prompt whether to remove destinations" },
        .logical = .{ .short = 'L', .desc = "Dereference TARGETs that are symbolic links" },
        .no_dereference = .{ .short = 'n', .desc = "Treat LINK_NAME as a normal file if it is a symbolic link to a directory" },
        .physical = .{ .short = 'P', .desc = "Make hard links directly to symbolic links" },
        .relative = .{ .short = 'r', .desc = "With -s, create links relative to link location" },
        .symbolic = .{ .short = 's', .desc = "Make symbolic links instead of hard links" },
        .target_directory = .{ .short = 't', .desc = "Specify the DIRECTORY in which to create the links", .value_name = "DIRECTORY" },
        .no_target_directory = .{ .short = 'T', .desc = "Treat LINK_NAME as a normal file always" },
        .verbose = .{ .short = 'v', .desc = "Print name of each linked file" },
    };
};

// Test helper function to create test files (standalone version)
fn createTestFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Security validation for paths
fn validatePath(path: []const u8) !void {
    // Check for empty path
    if (path.len == 0) {
        return error.EmptyPath;
    }

    // Check for null bytes
    if (std.mem.indexOf(u8, path, "\x00") != null) {
        return error.InvalidPath;
    }

    // First check for path traversal attempts before normalization
    // Split path into components and check each
    var it = std.mem.tokenizeScalar(u8, path, '/');
    var depth: i32 = 0;
    const is_absolute = std.fs.path.isAbsolute(path);

    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) {
            depth -= 1;
            // Going above root is suspicious
            if (depth < 0 and is_absolute) {
                return error.PathTraversalAttempt;
            }
        } else if (!std.mem.eql(u8, component, ".")) {
            depth += 1;
        }
    }

    // Check for system-critical paths
    const critical_paths = [_][]const u8{
        "/bin",  "/boot", "/dev",  "/etc", "/lib", "/lib32", "/lib64",
        "/proc", "/root", "/sbin", "/sys", "/usr", "/var",
    };

    // Normalize the path for checking
    var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
    const normalized = blk: {
        // Only normalize if the path exists or is absolute
        if (is_absolute) {
            break :blk std.fs.realpath(path, &normalized_buf) catch path;
        } else {
            // For relative paths that might not exist yet, we'll check as-is
            break :blk path;
        }
    };

    // Check if it's a critical system path
    for (critical_paths) |critical| {
        if (std.mem.eql(u8, normalized, critical)) {
            return error.SystemPathProtected;
        }
        // Check if path starts with critical path followed by /
        if (normalized.len > critical.len and
            normalized[critical.len] == '/' and
            std.mem.startsWith(u8, normalized, critical))
        {
            return error.SystemPathProtected;
        }
    }
}

/// Calculate relative path from one absolute path to another
fn makeRelativePath(allocator: std.mem.Allocator, from_abs: []const u8, to_abs: []const u8) ![]u8 {
    // Split both paths into components
    var from_parts = std.ArrayList([]const u8).init(allocator);
    defer from_parts.deinit();
    var to_parts = std.ArrayList([]const u8).init(allocator);
    defer to_parts.deinit();

    // Parse from path
    var from_it = std.mem.tokenizeScalar(u8, from_abs, '/');
    while (from_it.next()) |part| {
        try from_parts.append(part);
    }

    // Parse to path
    var to_it = std.mem.tokenizeScalar(u8, to_abs, '/');
    while (to_it.next()) |part| {
        try to_parts.append(part);
    }

    // Find common prefix
    var common_prefix_len: usize = 0;
    const min_len = @min(from_parts.items.len, to_parts.items.len);
    for (0..min_len) |i| {
        if (std.mem.eql(u8, from_parts.items[i], to_parts.items[i])) {
            common_prefix_len = i + 1;
        } else {
            break;
        }
    }

    // Build relative path
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    // Add ".." for each directory we need to go up from 'from' path
    const dirs_up = from_parts.items.len - common_prefix_len;
    for (0..dirs_up) |_| {
        if (result.items.len > 0) {
            try result.append('/');
        }
        try result.appendSlice("..");
    }

    // Add the remaining parts of 'to' path
    for (common_prefix_len..to_parts.items.len) |i| {
        if (result.items.len > 0) {
            try result.append('/');
        }
        try result.appendSlice(to_parts.items[i]);
    }

    // If result is empty, paths are the same
    if (result.items.len == 0) {
        try result.appendSlice(".");
    }

    return result.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Parse arguments using new parser
    const args = common.argparse.ArgParser.parseProcess(LnArgs, allocator) catch |err| {
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

    // Create options
    const options = LinkOptions{
        .force = args.force,
        .interactive = args.interactive,
        .logical = args.logical,
        .no_dereference = args.no_dereference,
        .physical = args.physical,
        .relative = args.relative,
        .symbolic = args.symbolic,
        .target_directory = args.target_directory,
        .no_target_directory = args.no_target_directory,
        .verbose = args.verbose,
    };

    const files = args.positionals;

    if (files.len == 0) {
        common.printError("missing file operand", .{});
        return common.Error.ArgumentError;
    }

    try createLinks(allocator, files, options);
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Usage: ln [OPTION]... [-T] TARGET LINK_NAME
        \\  or:  ln [OPTION]... TARGET
        \\  or:  ln [OPTION]... TARGET... DIRECTORY
        \\  or:  ln [OPTION]... -t DIRECTORY TARGET...
        \\In the 1st form, create a link to TARGET with the name LINK_NAME.
        \\In the 2nd form, create a link to TARGET in the current directory.
        \\In the 3rd and 4th forms, create links to each TARGET in DIRECTORY.
        \\Create hard links by default, symbolic links with --symbolic.
        \\By default, each destination (name of new link) should not already exist.
        \\When creating hard links, each TARGET must exist.  Symbolic links
        \\can hold arbitrary text; if later resolved, a relative link is
        \\interpreted in relation to its parent directory.
        \\
        \\      --backup[=CONTROL]       make a backup of each existing destination file
        \\  -b                           like --backup but does not accept an argument
        \\  -d, -F, --directory         allow the superuser to attempt to hard link
        \\                                 directories (this will probably fail due to
        \\                                 system restrictions, even for the superuser)
        \\  -f, --force                 remove existing destination files
        \\  -i, --interactive           prompt whether to remove destinations
        \\  -L, --logical               dereference TARGETs that are symbolic links
        \\  -n, --no-dereference        treat LINK_NAME as a normal file if
        \\                                 it is a symbolic link to a directory
        \\  -P, --physical              make hard links directly to symbolic links
        \\  -r, --relative              with -s, create links relative to link location
        \\  -s, --symbolic              make symbolic links instead of hard links
        \\  -S, --suffix=SUFFIX         override the usual backup suffix
        \\  -t, --target-directory=DIRECTORY  specify the DIRECTORY in which to create
        \\                                 the links
        \\  -T, --no-target-directory   treat LINK_NAME as a normal file always
        \\  -v, --verbose               print name of each linked file
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
    );
}

fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("ln ({s}) {s}\n", .{ common.name, common.version });
}

const LinkOptions = struct {
    force: bool = false,
    interactive: bool = false,
    logical: bool = false,
    no_dereference: bool = false,
    physical: bool = false,
    relative: bool = false,
    symbolic: bool = false,
    target_directory: ?[]const u8 = null,
    no_target_directory: bool = false,
    verbose: bool = false,
};

fn createLinks(allocator: std.mem.Allocator, files: []const []const u8, options: LinkOptions) !void {
    if (options.target_directory) |target_dir| {
        // Form 4: ln [OPTION]... -t DIRECTORY TARGET...
        // Validate the target directory path
        validatePath(target_dir) catch |err| {
            common.printError("invalid target directory '{s}': {}", .{ target_dir, err });
            return err;
        };

        // Check that target directory exists and is a directory
        const stat = std.fs.cwd().statFile(target_dir) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    common.printError("target '{s}' is not a directory", .{target_dir});
                    return common.Error.ArgumentError;
                },
                else => return err,
            }
        };

        if (stat.kind != .directory) {
            common.printError("target '{s}' is not a directory", .{target_dir});
            return common.Error.ArgumentError;
        }

        for (files) |target| {
            const link_name = std.fs.path.basename(target);
            const full_link_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, link_name });
            defer allocator.free(full_link_path);
            try createSingleLink(target, full_link_path, options);
        }
    } else if (files.len == 1) {
        // Form 2: ln [OPTION]... TARGET
        const target = files[0];
        const link_name = std.fs.path.basename(target);
        try createSingleLink(target, link_name, options);
    } else if (files.len == 2 and options.no_target_directory) {
        // Form 1: ln [OPTION]... [-T] TARGET LINK_NAME
        const target = files[0];
        const link_name = files[1];
        try createSingleLink(target, link_name, options);
    } else if (files.len >= 2) {
        // Form 3: ln [OPTION]... TARGET... DIRECTORY
        const directory = files[files.len - 1];

        // Check if the last argument is a directory
        const stat = std.fs.cwd().statFile(directory) catch |err| switch (err) {
            error.FileNotFound => {
                if (files.len == 2) {
                    // If only 2 arguments and directory doesn't exist, treat as Form 1
                    try createSingleLink(files[0], files[1], options);
                    return;
                } else {
                    common.printError("target '{s}' is not a directory", .{directory});
                    return common.Error.ArgumentError;
                }
            },
            else => return err,
        };

        if (stat.kind != .directory) {
            if (files.len == 2) {
                // If only 2 arguments and target is not directory, treat as Form 1
                try createSingleLink(files[0], files[1], options);
                return;
            } else {
                common.printError("target '{s}' is not a directory", .{directory});
                return common.Error.ArgumentError;
            }
        }

        // Create links in the directory
        for (files[0 .. files.len - 1]) |target| {
            const link_name = std.fs.path.basename(target);
            const full_link_path = try std.fs.path.join(allocator, &[_][]const u8{ directory, link_name });
            defer allocator.free(full_link_path);
            try createSingleLink(target, full_link_path, options);
        }
    } else {
        common.printError("missing destination file operand after '{s}'", .{files[0]});
        return common.Error.ArgumentError;
    }
}

fn createSingleLink(target: []const u8, link_name: []const u8, options: LinkOptions) !void {
    // Validate paths for security
    validatePath(target) catch |err| {
        common.printError("invalid target path '{s}': {}", .{ target, err });
        return err;
    };
    validatePath(link_name) catch |err| {
        common.printError("invalid link path '{s}': {}", .{ link_name, err });
        return err;
    };

    // Check if link already exists
    const link_exists = blk: {
        std.fs.cwd().access(link_name, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => break :blk true,
        };
        break :blk true;
    };

    if (link_exists and !options.force) {
        if (options.interactive) {
            const stdin = std.io.getStdIn().reader();
            const stdout = std.io.getStdOut().writer();

            try stdout.print("ln: replace '{s}'? ", .{link_name});

            var buffer: [10]u8 = undefined;
            const input = (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) orelse return;

            if (input.len == 0 or (input[0] != 'y' and input[0] != 'Y')) {
                return;
            }
        } else {
            common.printError("'{s}': File exists", .{link_name});
            return error.FileExists;
        }
    }

    // Remove existing link if force is enabled
    if (link_exists and options.force) {
        std.fs.cwd().deleteFile(link_name) catch |err| switch (err) {
            error.FileNotFound => {}, // Already removed
            else => {
                common.printError("cannot remove '{s}': {}", .{ link_name, err });
                return err;
            },
        };
    }

    if (options.symbolic) {
        // Create symbolic link
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var target_path = target;
        var allocated_path: ?[]u8 = null;
        defer if (allocated_path) |p| allocator.free(p);

        if (options.relative) {
            // Compute relative path from link location to target
            // First, get absolute paths
            var target_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
            var link_dir_abs_buf: [std.fs.max_path_bytes]u8 = undefined;

            const target_abs = blk: {
                if (std.fs.path.isAbsolute(target)) {
                    break :blk target;
                } else {
                    break :blk std.fs.realpath(target, &target_abs_buf) catch |err| {
                        common.printError("cannot resolve target path '{s}': {}", .{ target, err });
                        return err;
                    };
                }
            };

            // Get the directory where the link will be created
            const link_dir = std.fs.path.dirname(link_name) orelse ".";
            const link_dir_abs = blk: {
                if (std.fs.path.isAbsolute(link_dir)) {
                    break :blk link_dir;
                } else {
                    break :blk std.fs.realpath(link_dir, &link_dir_abs_buf) catch ".";
                }
            };

            // Calculate relative path
            allocated_path = makeRelativePath(allocator, link_dir_abs, target_abs) catch |err| {
                common.printError("cannot compute relative path: {}", .{err});
                return err;
            };
            target_path = allocated_path.?;
        }

        std.fs.cwd().symLink(target_path, link_name, .{}) catch |err| {
            common.printError("cannot create symbolic link '{s}' to '{s}': {}", .{ link_name, target, err });
            return err;
        };
    } else {
        // Create hard link
        // First check if target exists for hard links
        std.fs.cwd().access(target, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                common.printError("cannot link '{s}': No such file or directory", .{target});
                return error.FileNotFound;
            },
            else => {
                common.printError("cannot access '{s}': {}", .{ target, err });
                return err;
            },
        };

        std.posix.link(target, link_name) catch |err| {
            common.printError("cannot create link '{s}' to '{s}': {}", .{ link_name, target, err });
            return err;
        };
    }

    if (options.verbose) {
        const stdout = std.io.getStdOut().writer();
        if (options.symbolic) {
            try stdout.print("'{s}' -> '{s}'\n", .{ link_name, target });
        } else {
            try stdout.print("'{s}' => '{s}'\n", .{ link_name, target });
        }
    }
}

// Test-friendly version of createSingleLink that returns errors instead of calling exit
fn createSingleLinkTest(target: []const u8, link_name: []const u8, options: LinkOptions) !void {
    // Validate paths for security
    try validatePath(target);
    try validatePath(link_name);

    // Check if link already exists
    const link_exists = blk: {
        std.fs.cwd().access(link_name, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => break :blk true,
        };
        break :blk true;
    };

    if (link_exists and !options.force) {
        if (options.interactive) {
            // In test mode, assume user says no to interactive prompts
            return error.FileExists;
        } else {
            return error.FileExists;
        }
    }

    // Remove existing link if force is enabled
    if (link_exists and options.force) {
        std.fs.cwd().deleteFile(link_name) catch |err| switch (err) {
            error.FileNotFound => {}, // Already removed
            else => return err,
        };
    }

    if (options.symbolic) {
        // Create symbolic link
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var target_path = target;
        var allocated_path: ?[]u8 = null;
        defer if (allocated_path) |p| allocator.free(p);

        if (options.relative) {
            // Compute relative path from link location to target
            var target_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
            var link_dir_abs_buf: [std.fs.max_path_bytes]u8 = undefined;

            const target_abs = blk: {
                if (std.fs.path.isAbsolute(target)) {
                    break :blk target;
                } else {
                    break :blk try std.fs.realpath(target, &target_abs_buf);
                }
            };

            const link_dir = std.fs.path.dirname(link_name) orelse ".";
            const link_dir_abs = blk: {
                if (std.fs.path.isAbsolute(link_dir)) {
                    break :blk link_dir;
                } else {
                    break :blk try std.fs.realpath(link_dir, &link_dir_abs_buf);
                }
            };

            allocated_path = try makeRelativePath(allocator, link_dir_abs, target_abs);
            target_path = allocated_path.?;
        }

        try std.fs.cwd().symLink(target_path, link_name, .{});
    } else {
        // Create hard link
        // First check if target exists for hard links
        std.fs.cwd().access(target, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };

        try std.posix.link(target, link_name);
    }
}

// Test helper function for testing link creation
fn testCreateLink(target: []const u8, link_name: []const u8, options: LinkOptions, test_dir: std.fs.Dir) !void {
    // Save current directory
    const original_cwd_fd = try std.posix.open(".", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(original_cwd_fd);

    // Change to test directory
    try std.posix.fchdir(test_dir.fd);
    defer std.posix.fchdir(original_cwd_fd) catch {};

    // Create the actual target file for hard link tests
    if (!options.symbolic) {
        const target_file = std.fs.cwd().createFile(target, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => std.fs.cwd().openFile(target, .{}) catch return err,
            else => return err,
        };
        defer target_file.close();
    }

    try createSingleLinkTest(target, link_name, options);
}

test "ln creates hard link to existing file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target file in test directory
    try createTestFile(tmp_dir.dir, "target.txt", "test content");

    // Change to test directory and create hard link
    const original_cwd_fd = try std.posix.open(".", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(original_cwd_fd);
    try std.posix.fchdir(tmp_dir.dir.fd);
    defer std.posix.fchdir(original_cwd_fd) catch {};

    // Create hard link directly using test function
    try createSingleLinkTest("target.txt", "link.txt", .{});

    // Verify link was created
    const link_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "link.txt", 1024);
    defer testing.allocator.free(link_content);

    try testing.expectEqualStrings("test content", link_content);
}

test "ln creates symbolic link" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target file
    try createTestFile(tmp_dir.dir, "target.txt", "test content");

    // Change to test directory and create symbolic link
    const original_cwd_fd = try std.posix.open(".", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(original_cwd_fd);
    try std.posix.fchdir(tmp_dir.dir.fd);
    defer std.posix.fchdir(original_cwd_fd) catch {};

    try createSingleLinkTest("target.txt", "symlink.txt", .{ .symbolic = true });

    // Verify symbolic link was created
    const link_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "symlink.txt", 1024);
    defer testing.allocator.free(link_content);

    try testing.expectEqualStrings("test content", link_content);
}

test "ln fails on non-existent target for hard link" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const original_cwd_fd = try std.posix.open(".", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(original_cwd_fd);
    try std.posix.fchdir(tmp_dir.dir.fd);
    defer std.posix.fchdir(original_cwd_fd) catch {};

    // This should fail because hard links require existing targets
    const result = createSingleLinkTest("nonexistent.txt", "link.txt", .{});
    try testing.expectError(error.FileNotFound, result);
}

test "ln allows non-existent target for symbolic link" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const original_cwd_fd = try std.posix.open(".", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(original_cwd_fd);
    try std.posix.fchdir(tmp_dir.dir.fd);
    defer std.posix.fchdir(original_cwd_fd) catch {};

    // This should succeed because symbolic links can point to non-existent files
    try createSingleLinkTest("nonexistent.txt", "symlink.txt", .{ .symbolic = true });

    // Verify the symlink exists (but points to non-existent file)
    // Check that the link exists by reading the link target
    var buffer: [256]u8 = undefined;
    const target = std.fs.cwd().readLink("symlink.txt", &buffer) catch |err| switch (err) {
        error.NotLink => {
            try testing.expect(false); // Should be a link
            return;
        },
        else => return err,
    };
    try testing.expectEqualStrings("nonexistent.txt", target);
}

test "ln with force removes existing file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target and existing link
    try createTestFile(tmp_dir.dir, "target.txt", "new content");
    try createTestFile(tmp_dir.dir, "link.txt", "old content");

    const original_cwd_fd = try std.posix.open(".", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(original_cwd_fd);
    try std.posix.fchdir(tmp_dir.dir.fd);
    defer std.posix.fchdir(original_cwd_fd) catch {};

    // Force create hard link
    try createSingleLinkTest("target.txt", "link.txt", .{ .force = true });

    // Verify link was replaced
    const link_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "link.txt", 1024);
    defer testing.allocator.free(link_content);

    try testing.expectEqualStrings("new content", link_content);
}

test "ln fails without force on existing file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target and existing link
    try createTestFile(tmp_dir.dir, "target.txt", "new content");
    try createTestFile(tmp_dir.dir, "link.txt", "old content");

    const original_cwd_fd = try std.posix.open(".", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(original_cwd_fd);
    try std.posix.fchdir(tmp_dir.dir.fd);
    defer std.posix.fchdir(original_cwd_fd) catch {};

    // This should fail without force
    const result = createSingleLinkTest("target.txt", "link.txt", .{});
    try testing.expectError(error.FileExists, result);
}

test "ln creates relative symbolic link with -r" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a subdirectory structure
    try tmp_dir.dir.makeDir("subdir");
    try createTestFile(tmp_dir.dir, "target.txt", "test content");

    const original_cwd_fd = try std.posix.open(".", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(original_cwd_fd);
    try std.posix.fchdir(tmp_dir.dir.fd);
    defer std.posix.fchdir(original_cwd_fd) catch {};

    // Create relative symbolic link from subdir to parent dir file
    try createSingleLinkTest("target.txt", "subdir/link.txt", .{ .symbolic = true, .relative = true });

    // Verify the link was created with relative path
    var buffer: [256]u8 = undefined;
    const link_target = try std.fs.cwd().readLink("subdir/link.txt", &buffer);
    try testing.expectEqualStrings("../target.txt", link_target);

    // Verify the link works
    const link_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "subdir/link.txt", 1024);
    defer testing.allocator.free(link_content);
    try testing.expectEqualStrings("test content", link_content);
}

test "ln relative path calculation" {
    // Test the makeRelativePath function directly
    const test_cases = [_]struct {
        from: []const u8,
        to: []const u8,
        expected: []const u8,
    }{
        .{ .from = "/home/user/docs", .to = "/home/user/file.txt", .expected = "../file.txt" },
        .{ .from = "/home/user", .to = "/home/user/docs/file.txt", .expected = "docs/file.txt" },
        .{ .from = "/home/user/a", .to = "/home/user/b", .expected = "../b" },
        .{ .from = "/a/b/c", .to = "/x/y/z", .expected = "../../../x/y/z" },
        .{ .from = "/home", .to = "/home", .expected = "." },
    };

    for (test_cases) |tc| {
        const result = try makeRelativePath(testing.allocator, tc.from, tc.to);
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(tc.expected, result);
    }
}

test "ln path security validation" {
    // Test validatePath function

    // Valid paths should pass
    try validatePath("/home/user/file.txt");
    try validatePath("relative/path/file.txt");
    try validatePath("./file.txt");

    // Invalid paths should fail
    try testing.expectError(error.EmptyPath, validatePath(""));
    try testing.expectError(error.InvalidPath, validatePath("path\x00with\x00null"));
    try testing.expectError(error.SystemPathProtected, validatePath("/etc/passwd"));
    try testing.expectError(error.SystemPathProtected, validatePath("/bin/sh"));

    // Path traversal attempts - caught before normalization
    try testing.expectError(error.PathTraversalAttempt, validatePath("/../etc/passwd"));

    // Test a path traversal that doesn't end up in a system directory
    try testing.expectError(error.PathTraversalAttempt, validatePath("/../home/user"));
}

test "ln prevents creation of links to system paths" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const original_cwd_fd = try std.posix.open(".", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(original_cwd_fd);
    try std.posix.fchdir(tmp_dir.dir.fd);
    defer std.posix.fchdir(original_cwd_fd) catch {};

    // Try to create link to system path
    const result = createSingleLinkTest("/etc/passwd", "link.txt", .{ .symbolic = true });
    try testing.expectError(error.SystemPathProtected, result);
}

test "ln prevents creation of links in system directories" {
    // This test verifies we can't create links in protected directories
    const result = createSingleLinkTest("somefile.txt", "/etc/mylink", .{ .symbolic = true });
    try testing.expectError(error.SystemPathProtected, result);
}
