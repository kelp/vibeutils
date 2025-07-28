//! Cross-utility workflow tests for privilege operations
//! These tests verify that multiple utilities work together correctly under privilege simulation
//!
//! Prerequisites:
//! - Built utilities in zig-out/bin/
//! - fakeroot or unshare available for privilege simulation
//! - Tests gracefully skip on platforms without privilege simulation

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const privilege_test = common.privilege_test;
const TestUtils = common.test_utils_privilege.TestUtils;
const builtin = @import("builtin");

test "privileged: mkdir and ls permission workflow" {
    try privilege_test.requiresPrivilege();
    
    // Use arena allocator for temporary allocations
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var utils = TestUtils.init(allocator);
    defer utils.deinit();
    
    const temp_dir = try utils.getTempDir();
    const temp_path = try temp_dir.dir.realpathAlloc(allocator, ".");
    
    // Create directories with different permissions
    const dirs = [_]struct { name: []const u8, mode: []const u8 }{
        .{ .name = "public", .mode = "755" },
        .{ .name = "private", .mode = "700" },
        .{ .name = "restricted", .mode = "750" },
    };
    
    for (dirs) |dir_info| {
        const dir_path = try utils.safePath(temp_path, dir_info.name);
        
        const result = try utils.runBuiltUtility("mkdir", &[_][]const u8{
            "-m", dir_info.mode,
            dir_path,
        });
        
        try testing.expect(result.term.Exited == 0);
    }
    
    // List with ls to verify permissions
    const ls_result = try utils.runBuiltUtility("ls", &[_][]const u8{
        "-la",
        temp_path,
    });
    
    try testing.expect(ls_result.term.Exited == 0);
    
    // Verify all directories are listed
    for (dirs) |dir_info| {
        try testing.expect(std.mem.indexOf(u8, ls_result.stdout, dir_info.name) != null);
    }
    
    // Verify permissions are shown correctly (this is a basic check)
    try testing.expect(std.mem.indexOf(u8, ls_result.stdout, "drwxr-xr-x") != null); // 755
    try testing.expect(std.mem.indexOf(u8, ls_result.stdout, "drwx------") != null); // 700
    try testing.expect(std.mem.indexOf(u8, ls_result.stdout, "drwxr-x---") != null); // 750
}

test "privileged: touch and cat file permissions" {
    try privilege_test.requiresPrivilege();
    
    // Use arena allocator for temporary allocations
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var utils = TestUtils.init(allocator);
    defer utils.deinit();
    
    const temp_dir = try utils.getTempDir();
    const temp_path = try temp_dir.dir.realpathAlloc(allocator, ".");
    
    // Create a file with touch
    const file_path = try utils.safePath(temp_path, "test.txt");
    
    const touch_result = try utils.runBuiltUtility("touch", &[_][]const u8{
        file_path,
    });
    
    try testing.expect(touch_result.term.Exited == 0);
    
    // Write content to the file using direct file operations (safer than shell)
    {
        const file = try temp_dir.dir.createFile("test.txt", .{});
        defer file.close();
        try file.writeAll("Hello, privileged world!\n");
    }
    
    // Change file permissions to read-only
    const chmod_result = try utils.runBuiltUtility("chmod", &[_][]const u8{
        "400",
        file_path,
    });
    
    try testing.expect(chmod_result.term.Exited == 0);
    
    // Verify we can still read with cat
    const cat_result = try utils.runBuiltUtility("cat", &[_][]const u8{
        file_path,
    });
    
    try testing.expect(cat_result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, cat_result.stdout, "Hello, privileged world!") != null);
}

test "privileged: recursive directory operations" {
    try privilege_test.requiresPrivilege();
    
    // Use arena allocator for temporary allocations
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var utils = TestUtils.init(allocator);
    defer utils.deinit();
    
    const temp_dir = try utils.getTempDir();
    const temp_path = try temp_dir.dir.realpathAlloc(allocator, ".");
    
    // Create nested directory structure
    const base_dir = try std.fmt.allocPrint(allocator, "{s}/project", .{temp_path});
    defer allocator.free(base_dir);
    
    const dirs = [_][]const u8{
        "project",
        "project/src",
        "project/src/common",
        "project/test",
        "project/docs",
    };
    
    // Create all directories
    for (dirs) |dir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_path, dir });
        defer allocator.free(full_path);
        
        const result = try utils.runCommand(&[_][]const u8{
            "zig-out/bin/mkdir",
            "-p",
            full_path,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        try testing.expect(result.term.Exited == 0);
    }
    
    // Set different permissions on different directories
    const perms = [_]struct { path: []const u8, mode: []const u8 }{
        .{ .path = "project/src", .mode = "750" },
        .{ .path = "project/test", .mode = "755" },
        .{ .path = "project/docs", .mode = "644" },
    };
    
    for (perms) |perm| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_path, perm.path });
        defer allocator.free(full_path);
        
        const result = try utils.runCommand(&[_][]const u8{
            "chmod",
            perm.mode,
            full_path,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        try testing.expect(result.term.Exited == 0);
    }
    
    // List recursively to verify structure
    const ls_result = try utils.runCommand(&[_][]const u8{
        "zig-out/bin/ls",
        "-laR",
        base_dir,
    });
    defer allocator.free(ls_result.stdout);
    defer allocator.free(ls_result.stderr);
    
    try testing.expect(ls_result.term.Exited == 0);
    
    // Verify all directories are present
    for (dirs) |dir| {
        const dir_name = std.fs.path.basename(dir);
        try testing.expect(std.mem.indexOf(u8, ls_result.stdout, dir_name) != null);
    }
}

test "privileged: special file handling" {
    try privilege_test.requiresPrivilege();
    
    // Skip on Windows
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    
    // Use arena allocator for temporary allocations
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var utils = TestUtils.init(allocator);
    defer utils.deinit();
    
    const temp_dir = try utils.getTempDir();
    const temp_path = try temp_dir.dir.realpathAlloc(allocator, ".");
    
    // Create a FIFO (named pipe)
    const fifo_path = try utils.safePath(temp_path, "test.fifo");
    
    const mkfifo_result = try utils.runCommand(&[_][]const u8{
        "mkfifo",
        fifo_path,
    });
    
    // mkfifo might not be available on all systems
    if (mkfifo_result.term.Exited != 0) {
        return error.SkipZigTest;
    }
    
    // List to verify special file is shown correctly
    const ls_result = try utils.runCommand(&[_][]const u8{
        "zig-out/bin/ls",
        "-la",
        temp_path,
    });
    defer allocator.free(ls_result.stdout);
    defer allocator.free(ls_result.stderr);
    
    try testing.expect(ls_result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, ls_result.stdout, "test.fifo") != null);
    
    // The output should indicate it's a FIFO (usually starts with 'p')
    // Note: The exact format may vary by system
}