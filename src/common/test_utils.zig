const std = @import("std");

/// Create a test file with content in a directory
pub fn createTestFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Create an executable test file
pub fn createExecutableFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
    
    // Set execute permissions
    try file.chmod(0o755);
}