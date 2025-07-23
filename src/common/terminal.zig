const std = @import("std");
const builtin = @import("builtin");

/// Get terminal width in columns
pub fn getWidth() !u16 {
    if (builtin.os.tag == .windows) {
        // Windows implementation would use GetConsoleScreenBufferInfo
        return 80; // Default for now
    }
    
    // Unix-like systems: try ioctl first
    if (std.posix.isatty(std.io.getStdOut().handle)) {
        var ws: std.posix.winsize = undefined;
        const result = std.os.linux.ioctl(std.io.getStdOut().handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result == 0) {
            return ws.col;
        }
    }
    
    // Fallback: check COLUMNS environment variable
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLUMNS")) |cols| {
        defer std.heap.page_allocator.free(cols);
        return std.fmt.parseInt(u16, cols, 10) catch 80;
    } else |_| {}
    
    // Default fallback
    return 80;
}

/// Get terminal height in rows
pub fn getHeight() !u16 {
    if (builtin.os.tag == .windows) {
        // Windows implementation would use GetConsoleScreenBufferInfo
        return 24; // Default for now
    }
    
    // Unix-like systems: try ioctl first
    if (std.posix.isatty(std.io.getStdOut().handle)) {
        var ws: std.posix.winsize = undefined;
        const result = std.os.linux.ioctl(std.io.getStdOut().handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result == 0) {
            return ws.row;
        }
    }
    
    // Fallback: check LINES environment variable
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "LINES")) |lines| {
        defer std.heap.page_allocator.free(lines);
        return std.fmt.parseInt(u16, lines, 10) catch 24;
    } else |_| {}
    
    // Default fallback
    return 24;
}

test "terminal width detection" {
    // This test might fail in non-terminal environments
    const width = getWidth() catch 80;
    try std.testing.expect(width > 0);
    try std.testing.expect(width <= 1000); // Reasonable upper bound
}

test "terminal height detection" {
    // This test might fail in non-terminal environments
    const height = getHeight() catch 24;
    try std.testing.expect(height > 0);
    try std.testing.expect(height <= 1000); // Reasonable upper bound
}