const std = @import("std");
const builtin = @import("builtin");

/// Terminal dimension types
const Dimension = enum {
    width,
    height,
};

/// Generic helper function to get terminal dimensions
fn getTerminalDimension(allocator: std.mem.Allocator, dimension: Dimension) !u16 {
    if (builtin.os.tag == .windows) {
        // TODO: Windows implementation would use GetConsoleScreenBufferInfo
        return switch (dimension) {
            .width => @import("constants.zig").DEFAULT_TERMINAL_WIDTH,
            .height => @import("constants.zig").DEFAULT_TERMINAL_HEIGHT,
        };
    }

    // Unix-like systems: try ioctl first
    if (std.posix.isatty(std.fs.File.stdout().handle)) {
        var ws: std.posix.winsize = undefined;

        // Use the appropriate ioctl based on the OS
        const result = switch (builtin.os.tag) {
            .linux => std.os.linux.ioctl(std.fs.File.stdout().handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws)),
            .macos, .ios, .tvos, .watchos => std.c.ioctl(std.fs.File.stdout().handle, std.c.T.IOCGWINSZ, &ws),
            .freebsd, .netbsd, .openbsd, .dragonfly => std.c.ioctl(std.fs.File.stdout().handle, std.c.T.IOCGWINSZ, &ws),
            else => @as(usize, 1), // Force fallback for unknown systems
        };

        if (result == 0) {
            return switch (dimension) {
                .width => ws.col,
                .height => ws.row,
            };
        }
    }

    // Fallback: check environment variables
    const env_var = switch (dimension) {
        .width => "COLUMNS",
        .height => "LINES",
    };
    const default_value = switch (dimension) {
        .width => @import("constants.zig").DEFAULT_TERMINAL_WIDTH,
        .height => @import("constants.zig").DEFAULT_TERMINAL_HEIGHT,
    };

    if (std.process.getEnvVarOwned(allocator, env_var)) |env_value| {
        defer allocator.free(env_value);
        return std.fmt.parseInt(u16, env_value, 10) catch default_value;
    } else |_| {}

    // Default fallback
    return default_value;
}

/// Get terminal width in columns
pub fn getWidth(allocator: std.mem.Allocator) !u16 {
    return getTerminalDimension(allocator, .width);
}

/// Get terminal height in rows
pub fn getHeight(allocator: std.mem.Allocator) !u16 {
    return getTerminalDimension(allocator, .height);
}

test "terminal width detection" {
    // This test might fail in non-terminal environments
    const width = getWidth(std.testing.allocator) catch 80;
    try std.testing.expect(width > 0);
    try std.testing.expect(width <= 1000); // Reasonable upper bound
}

test "terminal height detection" {
    // This test might fail in non-terminal environments
    const height = getHeight(std.testing.allocator) catch 24;
    try std.testing.expect(height > 0);
    try std.testing.expect(height <= 1000); // Reasonable upper bound
}
