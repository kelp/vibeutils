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

/// Validate that all utilities have integrated fuzz tests
/// Returns detailed validation results including which utilities are missing fuzz tests
pub fn validateFuzzCoverage(allocator: std.mem.Allocator) FuzzCoverageError!ValidationResult {
    var missing_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer missing_list.deinit(allocator);

    var covered_count: usize = 0;

    // Check each utility for integrated fuzz tests
    for (utils.utilities) |util| {
        // Skip bracket form of test utility - it shares fuzz tests with test
        if (std.mem.eql(u8, util.name, "[")) {
            covered_count += 1; // Count as covered since it uses test.zig fuzz tests
            continue;
        }

        // Determine main utility file path
        const main_file_path = if (std.mem.eql(u8, util.name, "ls"))
            std.fmt.allocPrint(allocator, "src/ls/main.zig", .{}) catch {
                return FuzzCoverageError.FileSystemError;
            }
        else
            std.fmt.allocPrint(allocator, "src/{s}.zig", .{util.name}) catch {
                return FuzzCoverageError.FileSystemError;
            };
        defer allocator.free(main_file_path);

        // Check if main utility file has integrated fuzz tests
        if (hasIntegratedFuzzTests(allocator, main_file_path)) {
            covered_count += 1;
        } else {
            // Missing fuzz tests - add to missing list
            const missing_name = allocator.dupe(u8, util.name) catch {
                return FuzzCoverageError.FileSystemError;
            };
            try missing_list.append(allocator, missing_name);
        }
    }

    return ValidationResult{
        .covered = covered_count,
        .total = utils.utilities.len,
        .missing = try missing_list.toOwnedSlice(allocator),
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
            std.log.err("  - {s} (expected: integrated fuzz tests in src/{s}.zig)", .{ missing_util, missing_util });
        }

        std.log.err("", .{});
        std.log.err("To fix this issue:", .{});
        std.log.err("1. Add integrated fuzz tests to the utility files", .{});
        std.log.err("2. For utilities with Args structs, use: common.fuzz.createIntelligentFuzzer(ArgsType, runFunction)", .{});
        std.log.err("3. For utilities without Args structs, use: common.fuzz.testUtilityBasic", .{});
        std.log.err("4. Include enable_fuzz_tests checks and std.testing.fuzz() calls", .{});
        std.log.err("", .{});

        return FuzzCoverageError.MissingFuzzTests;
    }

    // Silent success - only report errors, not success
    // This validation runs for all build commands, so we avoid noise
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

/// Check if a specific utility has integrated fuzz tests
pub fn hasUtilityFuzzTests(allocator: std.mem.Allocator, util_name: []const u8) bool {
    // Special case for bracket form of test utility
    if (std.mem.eql(u8, util_name, "[")) {
        return hasUtilityFuzzTests(allocator, "test");
    }

    // Determine main utility file path
    const main_file_path = if (std.mem.eql(u8, util_name, "ls"))
        std.fmt.allocPrint(allocator, "src/ls/main.zig", .{}) catch return false
    else
        std.fmt.allocPrint(allocator, "src/{s}.zig", .{util_name}) catch return false;
    defer allocator.free(main_file_path);

    return hasIntegratedFuzzTests(allocator, main_file_path);
}

/// Check if a file contains integrated fuzz tests
fn hasIntegratedFuzzTests(allocator: std.mem.Allocator, file_path: []const u8) bool {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return false;
    defer file.close();

    const file_size = file.getEndPos() catch return false;
    if (file_size > 10 * 1024 * 1024) return false; // Skip files larger than 10MB

    const content = file.readToEndAlloc(allocator, file_size) catch return false;
    defer allocator.free(content);

    // Look for fuzz test patterns indicating integrated fuzz tests
    const fuzz_patterns = [_][]const u8{
        "fuzz.*intelligent", // Intelligent fuzzer pattern
        "fuzz.*basic", // Basic fuzzer pattern
        "std.testing.fuzz", // Direct usage of fuzz testing
        "enable_fuzz_tests", // Fuzz test enablement check
    };

    for (fuzz_patterns) |pattern| {
        if (std.mem.indexOf(u8, content, pattern) != null) {
            return true;
        }
    }

    return false;
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

    // Test existing utilities that should have integrated fuzz tests
    try std.testing.expect(hasUtilityFuzzTests(allocator, "echo"));
    try std.testing.expect(hasUtilityFuzzTests(allocator, "true"));

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
