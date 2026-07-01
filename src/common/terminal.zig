const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig");

/// Terminal dimension types
const Dimension = enum {
    width,
    height,
};

/// Generic helper function to get terminal dimensions
fn getTerminalDimension(allocator: std.mem.Allocator, dimension: Dimension) !u16 {
    // Fallback dimensions must be usable (nonzero) column/row counts.
    std.debug.assert(@import("constants.zig").DEFAULT_TERMINAL_WIDTH > 0);
    std.debug.assert(@import("constants.zig").DEFAULT_TERMINAL_HEIGHT > 0);
    if (builtin.os.tag == .windows) {
        // TODO: Windows implementation would use GetConsoleScreenBufferInfo
        return switch (dimension) {
            .width => @import("constants.zig").DEFAULT_TERMINAL_WIDTH,
            .height => @import("constants.zig").DEFAULT_TERMINAL_HEIGHT,
        };
    }

    // Unix-like systems: try ioctl first
    if (std.c.isatty(std.Io.File.stdout().handle) != 0) {
        var ws: std.c.winsize = undefined;

        // Use the appropriate ioctl based on the OS
        const result = switch (builtin.os.tag) {
            .linux => std.os.linux.ioctl(
                std.Io.File.stdout().handle,
                std.os.linux.T.IOCGWINSZ,
                @intFromPtr(&ws),
            ),
            .macos, .ios, .tvos, .watchos => std.c.ioctl(
                std.Io.File.stdout().handle,
                std.c.T.IOCGWINSZ,
                &ws,
            ),
            .freebsd, .netbsd, .openbsd, .dragonfly => std.c.ioctl(
                std.Io.File.stdout().handle,
                std.c.T.IOCGWINSZ,
                &ws,
            ),
            else => @as(usize, 1), // Force fallback for unknown systems
        };

        if (result == 0) {
            return switch (dimension) {
                .width => ws.col,
                .height => ws.row,
            };
        }
    }

    // Fallback: check environment variables via env.getEnv (works without libc)
    _ = allocator;
    const env_var = switch (dimension) {
        .width => "COLUMNS",
        .height => "LINES",
    };
    const default_value = switch (dimension) {
        .width => @import("constants.zig").DEFAULT_TERMINAL_WIDTH,
        .height => @import("constants.zig").DEFAULT_TERMINAL_HEIGHT,
    };

    if (env.getEnv(env_var)) |env_value| {
        return std.fmt.parseInt(u16, env_value, 10) catch default_value;
    }

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
