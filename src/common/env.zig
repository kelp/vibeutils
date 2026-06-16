/// Environment variable and terminal detection helpers that work without libc.
///
/// In test builds (common tests run without -lc), reads from std.testing.environ
/// and std.Io.File.isTty. In release builds (utilities link libc), delegates
/// to std.c.getenv and std.c.isatty.
const std = @import("std");
const builtin = @import("builtin");

/// Look up an environment variable by name.
///
/// Returns null if the variable is not set.
pub fn getEnv(key: []const u8) ?[]const u8 {
    // When libc is linked, use C getenv so that C setenv/unsetenv calls
    // (e.g., in tests that manipulate the process environment) are visible.
    if (builtin.link_libc) {
        var key_buf: [256]u8 = undefined;
        if (key.len >= key_buf.len) return null;
        // The guard above returns early for any key too large for the buffer,
        // so reaching here means the copy and sentinel write are in bounds.
        std.debug.assert(key.len < key_buf.len);
        @memcpy(key_buf[0..key.len], key);
        key_buf[key.len] = 0;
        // Postcondition of the NUL-sentinel write, paired with the bounds
        // invariant before forming the sentinel-terminated slice below.
        std.debug.assert(key_buf[key.len] == 0);
        const ptr = std.c.getenv(key_buf[0..key.len :0]) orelse return null;
        return std.mem.span(ptr);
    }
    // Without libc (common-only tests), use the Zig testing environ.
    if (builtin.is_test) {
        const result = std.testing.environ.getPosix(key);
        if (result) |val| return val;
        return null;
    }
    return null;
}

/// Check if a file descriptor refers to a terminal.
pub fn isTty(fd: std.posix.fd_t) bool {
    if (builtin.is_test) {
        const io = std.testing.io;
        const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
        return file.isTty(io) catch false;
    } else {
        return std.c.isatty(fd) != 0;
    }
}
