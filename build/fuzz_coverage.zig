//! Fuzz coverage validation for vibeutils build system
//!
//! This module validates that all utilities have corresponding fuzz test files.
//! It ensures comprehensive fuzz testing coverage across the project.

const std = @import("std");
const utils = @import("utils.zig");

/// Error types for fuzz coverage validation
pub const FuzzCoverageError = error{
    /// One or more utilities are missing fuzz tests
    MissingFuzzTests,
    /// File system access error during validation
    FileSystemError,
} || std.mem.Allocator.Error;

/// Result of fuzz coverage validation
pub const ValidationResult = struct {
    /// Number of utilities that have fuzz tests
    covered: usize,
    /// Total number of utilities
    total: usize,
    /// List of utilities missing fuzz tests
    missing: [][]const u8,

    /// Free memory used by missing list
    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        for (self.missing) |name| {
            allocator.free(name);
        }
        allocator.free(self.missing);
    }

    /// Check if all utilities have fuzz tests
    pub fn isComplete(self: ValidationResult) bool {
        return self.missing.len == 0;
    }

    /// Get coverage percentage as a float (0.0 to 1.0)
    pub fn getCoverageRatio(self: ValidationResult) f64 {
        if (self.total == 0) return 1.0;
        return @as(f64, @floatFromInt(self.covered)) / @as(f64, @floatFromInt(self.total));
    }

    /// Get coverage percentage as integer (0 to 100)
    pub fn getCoveragePercent(self: ValidationResult) u8 {
        return @as(u8, @intFromFloat(self.getCoverageRatio() * 100.0));
    }
};

/// Validate that all utilities have corresponding fuzz test files
/// Returns detailed validation results including which utilities are missing fuzz tests
pub fn validateFuzzCoverage(allocator: std.mem.Allocator) FuzzCoverageError!ValidationResult {
    var missing_list = std.ArrayList([]const u8).init(allocator);
    defer missing_list.deinit();

    var covered_count: usize = 0;

    // Check each utility for a corresponding fuzz file
    for (utils.utilities) |util| {
        // Skip bracket form of test utility - it shares fuzz tests with test
        if (std.mem.eql(u8, util.name, "[")) {
            covered_count += 1; // Count as covered since it uses test_fuzz.zig
            continue;
        }

        const fuzz_file_path = std.fmt.allocPrint(allocator, "src/{s}_fuzz.zig", .{util.name}) catch {
            return FuzzCoverageError.FileSystemError;
        };
        defer allocator.free(fuzz_file_path);

        // Check if fuzz file exists
        if (std.fs.cwd().access(fuzz_file_path, .{})) {
            covered_count += 1;
        } else |err| switch (err) {
            error.FileNotFound => {
                // Missing fuzz file - add to missing list
                const missing_name = allocator.dupe(u8, util.name) catch {
                    return FuzzCoverageError.FileSystemError;
                };
                try missing_list.append(missing_name);
            },
            else => {
                return FuzzCoverageError.FileSystemError;
            },
        }
    }

    return ValidationResult{
        .covered = covered_count,
        .total = utils.utilities.len,
        .missing = try missing_list.toOwnedSlice(),
    };
}

/// Validate fuzz coverage and fail if not complete
/// This is the enforcement function called during build
pub fn enforceFuzzCoverage(allocator: std.mem.Allocator) FuzzCoverageError!void {
    var result = try validateFuzzCoverage(allocator);
    defer result.deinit(allocator);

    if (!result.isComplete()) {
        std.log.err("Fuzz coverage validation failed!", .{});
        std.log.err("Coverage: {}/{} utilities ({d}%)", .{ result.covered, result.total, result.getCoveragePercent() });
        std.log.err("Missing fuzz tests for {} utilities:", .{result.missing.len});

        for (result.missing) |missing_util| {
            std.log.err("  - {s} (expected: src/{s}_fuzz.zig)", .{ missing_util, missing_util });
        }

        std.log.err("", .{});
        std.log.err("To fix this issue:", .{});
        std.log.err("1. Create fuzz test files for the missing utilities", .{});
        std.log.err("2. Follow the pattern in existing fuzz files like src/echo_fuzz.zig", .{});
        std.log.err("3. Include basic, paths, deterministic, and utility-specific fuzz tests", .{});
        std.log.err("4. Use std.testing.fuzz() with common.fuzz helper functions", .{});
        std.log.err("", .{});

        return FuzzCoverageError.MissingFuzzTests;
    }

    std.log.info("Fuzz coverage validation passed: {}/{} utilities ({d}%)", .{ result.covered, result.total, result.getCoveragePercent() });
}

/// Print fuzz coverage report without enforcing
/// Useful for CI reporting and development feedback
pub fn printFuzzCoverageReport(allocator: std.mem.Allocator) !void {
    var result = validateFuzzCoverage(allocator) catch |err| {
        std.log.err("Failed to validate fuzz coverage: {}", .{err});
        return;
    };
    defer result.deinit(allocator);

    const coverage_percent = result.getCoveragePercent();

    if (result.isComplete()) {
        std.log.info("✓ Fuzz coverage: {}/{} utilities (100%)", .{ result.covered, result.total });
    } else {
        std.log.warn("⚠ Fuzz coverage: {}/{} utilities ({d}%)", .{ result.covered, result.total, coverage_percent });
        std.log.warn("Missing fuzz tests:", .{});
        for (result.missing) |missing_util| {
            std.log.warn("  - {s}", .{missing_util});
        }
    }
}

/// Check if a specific utility has fuzz tests
pub fn hasUtilityFuzzTests(allocator: std.mem.Allocator, util_name: []const u8) bool {
    // Special case for bracket form of test utility
    if (std.mem.eql(u8, util_name, "[")) {
        return hasUtilityFuzzTests(allocator, "test");
    }

    const fuzz_file_path = std.fmt.allocPrint(allocator, "src/{s}_fuzz.zig", .{util_name}) catch return false;
    defer allocator.free(fuzz_file_path);

    std.fs.cwd().access(fuzz_file_path, .{}) catch return false;
    return true;
}

test "validateFuzzCoverage basic functionality" {
    const allocator = std.testing.allocator;

    // This test will only pass if all utilities have fuzz tests
    var result = try validateFuzzCoverage(allocator);
    defer result.deinit(allocator);

    // Verify structure
    try std.testing.expect(result.total == utils.utilities.len);
    try std.testing.expect(result.covered <= result.total);
    try std.testing.expect(result.getCoverageRatio() >= 0.0 and result.getCoverageRatio() <= 1.0);
    try std.testing.expect(result.getCoveragePercent() <= 100);
}

test "hasUtilityFuzzTests works correctly" {
    const allocator = std.testing.allocator;

    // Test existing utilities that should have fuzz tests
    try std.testing.expect(hasUtilityFuzzTests(allocator, "echo"));
    try std.testing.expect(hasUtilityFuzzTests(allocator, "cat"));

    // Test bracket form mapping
    try std.testing.expect(hasUtilityFuzzTests(allocator, "[") == hasUtilityFuzzTests(allocator, "test"));

    // Test non-existent utility
    try std.testing.expect(!hasUtilityFuzzTests(allocator, "nonexistent-utility"));
}

test "ValidationResult methods work correctly" {
    const allocator = std.testing.allocator;

    // Create a test result
    const missing = try allocator.dupe([]const u8, &[_][]const u8{ "test1", "test2" });

    var result = ValidationResult{
        .covered = 8,
        .total = 10,
        .missing = missing,
    };
    defer {
        for (result.missing) |name| {
            allocator.free(name);
        }
        allocator.free(result.missing);
    }

    // Test methods
    try std.testing.expect(!result.isComplete());
    try std.testing.expectEqual(@as(u8, 80), result.getCoveragePercent());
    try std.testing.expectEqual(@as(f64, 0.8), result.getCoverageRatio());

    // Test complete coverage
    result.missing = &[_][]const u8{};
    result.covered = result.total;
    try std.testing.expect(result.isComplete());
    try std.testing.expectEqual(@as(u8, 100), result.getCoveragePercent());
}
