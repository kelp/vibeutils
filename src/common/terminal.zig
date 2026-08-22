const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig");
const constants = @import("constants.zig");

/// Terminal dimension types
const Dimension = enum {
    width,
    height,
};

fn resolveDimension(ioctl_value: ?u16, env_text: ?[]const u8, default: u16) u16 {
    // Callers must supply a usable fallback; the postcondition below can
    // only fire when this precondition is violated.
    std.debug.assert(default > 0);

    const result = resolved: {
        if (ioctl_value) |value| {
            if (value > 0) break :resolved value;
        }
        const text = env_text orelse break :resolved default;
        const parsed = std.fmt.parseInt(u16, text, 10) catch break :resolved default;
        if (parsed == 0) break :resolved default;
        break :resolved parsed;
    };
    // A zero ioctl value or a missing/empty/non-numeric/zero environment
    // value fell back to the default above, so the result is never zero.
    std.debug.assert(result > 0);
    return result;
}

/// Query the kernel for the stdout window size. Returns null when stdout is
/// not a terminal or the ioctl fails. A reported size of 0 is returned as-is
/// so that resolveDimension can fall through to the environment and default.
fn queryWinsize(dimension: Dimension) ?u16 {
    std.debug.assert(builtin.os.tag != .windows);
    const stdout_handle = std.Io.File.stdout().handle;
    std.debug.assert(stdout_handle >= 0);

    if (std.c.isatty(stdout_handle) == 0) return null;

    var ws: std.c.winsize = undefined;
    const result = switch (builtin.os.tag) {
        .linux => std.os.linux.ioctl(
            stdout_handle,
            std.os.linux.T.IOCGWINSZ,
            @intFromPtr(&ws),
        ),
        .macos, .ios, .tvos, .watchos => std.c.ioctl(
            stdout_handle,
            std.c.T.IOCGWINSZ,
            &ws,
        ),
        .freebsd, .netbsd, .openbsd, .dragonfly => std.c.ioctl(
            stdout_handle,
            std.c.T.IOCGWINSZ,
            &ws,
        ),
        else => return null, // Force fallback for unknown systems
    };
    if (result != 0) return null;

    return switch (dimension) {
        .width => ws.col,
        .height => ws.row,
    };
}

/// Generic helper function to get terminal dimensions
fn getTerminalDimension(allocator: std.mem.Allocator, dimension: Dimension) !u16 {
    // Fallback dimensions must be usable (nonzero) column/row counts.
    std.debug.assert(constants.DEFAULT_TERMINAL_WIDTH > 0);
    std.debug.assert(constants.DEFAULT_TERMINAL_HEIGHT > 0);
    _ = allocator;

    if (builtin.os.tag == .windows) {
        // TODO: Windows implementation would use GetConsoleScreenBufferInfo
        return switch (dimension) {
            .width => constants.DEFAULT_TERMINAL_WIDTH,
            .height => constants.DEFAULT_TERMINAL_HEIGHT,
        };
    }

    // ioctl first, then environment, then default — all folded through the
    // pure resolver so a zero from any source falls through to the next.
    const ioctl_value = queryWinsize(dimension);
    const env_text = env.getEnv(switch (dimension) {
        .width => "COLUMNS",
        .height => "LINES",
    });
    const default_value: u16 = switch (dimension) {
        .width => constants.DEFAULT_TERMINAL_WIDTH,
        .height => constants.DEFAULT_TERMINAL_HEIGHT,
    };
    return resolveDimension(ioctl_value, env_text, default_value);
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

test "terminal resolveDimension uses positive ioctl" {
    const result = resolveDimension(80, "0", constants.DEFAULT_TERMINAL_WIDTH);

    try std.testing.expectEqual(@as(u16, 80), result);
    try std.testing.expect(result > 0);
}

test "terminal resolveDimension falls back on empty env" {
    const result = resolveDimension(null, "", constants.DEFAULT_TERMINAL_WIDTH);

    try std.testing.expectEqual(constants.DEFAULT_TERMINAL_WIDTH, result);
    try std.testing.expect(result > 0);
}

test "terminal resolveDimension falls back on non-numeric env" {
    const result = resolveDimension(null, "abc", constants.DEFAULT_TERMINAL_WIDTH);

    try std.testing.expectEqual(constants.DEFAULT_TERMINAL_WIDTH, result);
    try std.testing.expect(result > 0);
}

test "terminal resolveDimension uses positive env when ioctl is null" {
    const result = resolveDimension(null, "120", constants.DEFAULT_TERMINAL_WIDTH);

    try std.testing.expectEqual(@as(u16, 120), result);
    try std.testing.expect(result > 0);
}

test "terminal resolveDimension falls back when ioctl is 0" {
    const result = resolveDimension(0, "120", constants.DEFAULT_TERMINAL_WIDTH);

    try std.testing.expectEqual(@as(u16, 120), result);
    try std.testing.expect(result > 0);
}

test "terminal resolveDimension falls back when COLUMNS is 0" {
    const result = resolveDimension(null, "0", constants.DEFAULT_TERMINAL_WIDTH);

    try std.testing.expectEqual(constants.DEFAULT_TERMINAL_WIDTH, result);
    try std.testing.expect(result > 0);
}

test "terminal resolveDimension falls back when LINES is 0" {
    const result = resolveDimension(null, "0", constants.DEFAULT_TERMINAL_HEIGHT);

    try std.testing.expectEqual(constants.DEFAULT_TERMINAL_HEIGHT, result);
    try std.testing.expect(result > 0);
}

test "terminal getWidth falls back when COLUMNS is 0 off tty" {
    const saved_overrides = env.test_overrides;
    defer env.test_overrides = saved_overrides;
    env.test_overrides = &.{.{ .key = "COLUMNS", .value = "0" }};

    if (std.c.isatty(std.Io.File.stdout().handle) != 0) {
        return error.SkipZigTest;
    }

    const width = try getWidth(std.testing.allocator);
    try std.testing.expectEqual(constants.DEFAULT_TERMINAL_WIDTH, width);
    try std.testing.expect(width > 0);
}
