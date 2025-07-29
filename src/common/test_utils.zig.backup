const std = @import("std");

var test_counter: u32 = 0;

/// Generate a unique test file name based on test name and counter
pub fn uniqueTestName(allocator: std.mem.Allocator, base_name: []const u8) ![]u8 {
    test_counter += 1;
    return try std.fmt.allocPrint(allocator, "{s}_{d}_{d}", .{ base_name, std.time.timestamp(), test_counter });
}

/// Create a test file with content in a directory
pub fn createTestFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Create a uniquely named test file with content
pub fn createUniqueTestFile(dir: std.fs.Dir, allocator: std.mem.Allocator, base_name: []const u8, content: []const u8) ![]u8 {
    const unique_name = try uniqueTestName(allocator, base_name);
    try createTestFile(dir, unique_name, content);
    return unique_name;
}

/// Create an executable test file
pub fn createExecutableFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);

    // Set execute permissions
    try file.chmod(0o755);
}
