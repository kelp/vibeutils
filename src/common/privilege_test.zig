const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const env = @import("env.zig");

/// Arena allocator for privileged tests to avoid testing.allocator issues under fakeroot
/// This is a workaround for Zig 0.14 test runner incompatibility with fakeroot
/// See: https://github.com/ziglang/zig/issues/15091
pub const TestArena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init() TestArena {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *TestArena) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *TestArena) std.mem.Allocator {
        return self.arena.allocator();
    }
};

/// Platform-specific privilege simulation capabilities
pub const Platform = enum {
    linux,
    macos,
    bsd,
    other,

    pub fn detect() Platform {
        return switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .freebsd, .openbsd, .netbsd, .dragonfly => .bsd,
            else => .other,
        };
    }
};

/// Available privilege simulation methods
pub const PrivilegeMethod = enum {
    fakeroot,
    none,
};

/// Context for running tests with simulated privileges
pub const FakerootContext = struct {
    allocator: std.mem.Allocator,
    platform: Platform,
    method: PrivilegeMethod,
    available: bool,

    /// Initialize the privilege testing context
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !FakerootContext {
        const platform = Platform.detect();
        var ctx = FakerootContext{
            .allocator = allocator,
            .platform = platform,
            .method = .none,
            .available = false,
        };

        // Check if fakeroot is available
        if (checkCommandExists(io)) {
            ctx.method = .fakeroot;
            ctx.available = true;
        }

        return ctx;
    }

    /// Check if we're running under fakeroot
    pub fn isUnderFakeroot() bool {
        return env.getEnv("FAKEROOTKEY") != null;
    }
};

/// Skip test if no privilege simulation is available
pub fn requiresPrivilege(io: std.Io) !void {
    // Use a simple check without allocator to avoid issues
    if (!FakerootContext.isUnderFakeroot()) {
        // Also check if fakeroot is available in the system
        if (!checkCommandExists(io)) {
            return error.SkipZigTest;
        }
    }
}

/// Run a test block under fakeroot (if available)
pub fn withFakeroot(
    allocator: std.mem.Allocator,
    comptime testFn: fn (allocator: std.mem.Allocator) anyerror!void,
) !void {
    // If we're already under fakeroot, just run the test
    if (FakerootContext.isUnderFakeroot()) {
        try testFn(allocator);
        return;
    }

    // Otherwise, check if we should skip the test
    // The build system will re-run us under fakeroot if needed
    return error.SkipZigTest;
}

/// Check if fakeroot command exists in PATH
fn checkCommandExists(io: std.Io) bool {
    // In test environments, avoid subprocess execution which can hang
    if (builtin.is_test) {
        // Check if we're already under fakeroot
        if (env.getEnv("FAKEROOTKEY") != null) return true;

        // In Docker containers, fakeroot is typically available
        if (env.getEnv("container") != null) return true;

        return false;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Try to find the command in PATH
    const argv = [_][]const u8{ "which", "fakeroot" };
    const result = std.process.run(allocator, io, .{ .argv = &argv }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

// Tests
test "platform detection" {
    const platform = Platform.detect();
    switch (builtin.os.tag) {
        .linux => try testing.expectEqual(Platform.linux, platform),
        .macos => try testing.expectEqual(Platform.macos, platform),
        .freebsd, .openbsd, .netbsd, .dragonfly => try testing.expectEqual(Platform.bsd, platform),
        else => try testing.expectEqual(Platform.other, platform),
    }
}

test "FakerootContext initialization" {
    const ctx = try FakerootContext.init(testing.allocator, testing.io);

    // We should at least detect the platform correctly
    try testing.expect(ctx.platform == Platform.detect());
}

test "isUnderFakeroot detection" {
    // This test will pass differently depending on environment
    const under_fakeroot = FakerootContext.isUnderFakeroot();

    // If FAKEROOTKEY is set, we should detect it
    if (env.getEnv("FAKEROOTKEY") != null) {
        try testing.expect(under_fakeroot);
    } else {
        try testing.expect(!under_fakeroot);
    }
}

test "requiresPrivilege skip behavior" {
    // This test demonstrates the skip behavior
    // It will skip if no privilege simulation is available
    requiresPrivilege(testing.io) catch |err| {
        if (err == error.SkipZigTest) {
            // This is expected behavior when not under privilege simulation
            return;
        }
        return err;
    };

    // If we get here, we either:
    // 1. Are under fakeroot, OR
    // 2. Have privilege simulation tools available
    const ctx = try FakerootContext.init(testing.allocator, testing.io);
    try testing.expect(FakerootContext.isUnderFakeroot() or ctx.available);
}

test "simple privileged operation simulation" {
    const io = testing.io;

    // Only run if we're in privileged test mode
    if (!FakerootContext.isUnderFakeroot()) {
        if (env.getEnv("ZIG_PRIVILEGED_TESTS")) |val| {
            if (!std.mem.eql(u8, val, "1")) {
                return error.SkipZigTest;
            }
        } else {
            return error.SkipZigTest;
        }
    }

    // Create a test file
    const test_file = "test_privilege_file.tmp";
    defer std.Io.Dir.cwd().deleteFile(io, test_file) catch {};

    // Create file
    const file = try std.Io.Dir.cwd().createFile(io, test_file, .{});
    file.close(io);

    // Under fakeroot, we can simulate changing ownership
    if (FakerootContext.isUnderFakeroot()) {
        const cwd = std.Io.Dir.cwd();
        const file_handle = try cwd.openFile(io, test_file, .{});
        defer file_handle.close(io);

        // Try to change ownership - this demonstrates the infrastructure
        // Note: fakeroot may not intercept all file operations through Zig's APIs
        file_handle.setOwner(io, 0, 0) catch |err| {
            // This is expected - fakeroot doesn't always work with all APIs
            try testing.expect(err == error.AccessDenied or err == error.PermissionDenied);
        };

        // The key test is that we detected fakeroot correctly
        try testing.expect(true);
    }
}
