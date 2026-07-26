/// Environment variable and terminal detection helpers that work without libc.
///
/// The branch is on builtin.link_libc, not on builtin.is_test: every
/// lib.zig-rooted test root links libc as of issue #95, so the common tests
/// take the std.c.getenv / std.c.isatty path too. Builds without libc read
/// from std.testing.environ and std.Io.File.isTty instead.
///
/// Tests never mutate the process environment; they stage values in the
/// test-only `test_overrides` overlay below.
const std = @import("std");
const builtin = @import("builtin");

/// A single test-only environment entry. A `null` value means the key
/// behaves as unset.
pub const Override = struct {
    key: []const u8,
    value: ?[]const u8,
};

/// Test-only overlay consulted by getEnv before the real environment.
///
/// Tests stage environment state here instead of calling libc
/// setenv/unsetenv. glibc's unsetenv compacts the `environ` array in
/// place, which invalidates the view Zig 0.16 captures once at startup
/// into std.process.Init / std.testing.environ; the test runner's
/// error-return-trace path then null-unwraps in Environ.scan and
/// self-deadlocks, hanging the whole suite instead of reporting the
/// failure (issue #95 fallout).
///
/// Every read of this is gated on builtin.is_test, so release builds
/// carry neither the lookup nor a reference to the storage.
pub var test_overrides: []const Override = &.{};

/// Upper bound on staged overrides, so the overlay scan is a bounded
/// loop over a slice a test controls entirely.
const test_overrides_count_max: u32 = 32;

/// Result of consulting the test overlay. `absent` (not named by the
/// overlay) is deliberately distinct from `unset` (named, with a null
/// value): only the latter shadows a variable that the real
/// environment does define.
const OverrideLookup = union(enum) {
    absent,
    unset,
    value: []const u8,
};

/// Find `key` in the test overlay. Callers must gate on
/// builtin.is_test so this is comptime-eliminated elsewhere.
fn lookupOverride(key: []const u8) OverrideLookup {
    std.debug.assert(builtin.is_test);
    std.debug.assert(test_overrides.len <= test_overrides_count_max);
    for (test_overrides) |override| {
        if (!std.mem.eql(u8, override.key, key)) continue;
        const value = override.value orelse return .unset;
        return .{ .value = value };
    }
    return .absent;
}

/// Look up an environment variable by name.
///
/// Returns null if the variable is not set.
pub fn getEnv(key: []const u8) ?[]const u8 {
    // The test overlay outranks the real environment so that tests can
    // stage values without mutating the process environment.
    if (builtin.is_test) {
        switch (lookupOverride(key)) {
            .value => |value| return value,
            .unset => return null,
            .absent => {},
        }
    }
    // When libc is linked, use C getenv so that the process environment
    // inherited at startup is visible.
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
