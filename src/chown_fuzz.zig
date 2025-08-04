//! Streamlined fuzz tests for chown utility
//!
//! Chown changes file ownership and should handle all owner:group formats gracefully.
//! Tests verify the utility processes ownership specifications correctly without panicking.

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const chown_util = @import("chown.zig");

// Create standardized fuzz tests using the unified builder
const ChownFuzzTests = common.fuzz.createUtilityFuzzTests(chown_util.runChown);

test "chown fuzz basic" {
    try std.testing.fuzz(testing.allocator, ChownFuzzTests.testBasic, .{});
}

test "chown fuzz paths" {
    try std.testing.fuzz(testing.allocator, ChownFuzzTests.testPaths, .{});
}

test "chown fuzz deterministic" {
    try std.testing.fuzz(testing.allocator, ChownFuzzTests.testDeterministic, .{});
}

test "chown fuzz owner specifications" {
    try std.testing.fuzz(testing.allocator, testChownOwnerSpecs, .{});
}

fn testChownOwnerSpecs(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate various owner:group specifications
    const owner_specs = [_][]const u8{
        "root",       "nobody",     "daemon",           "www-data",
        "1000",       "0",          "65534",            "999999",
        "user:group", "root:wheel", "nobody:nogroup",   ":group",
        ":wheel",     ":1000",      "user:",            "root:",
        "1000:",      "1000:1000",  "0:0",              "65534:65534",
        "",           ":",          "user:group:extra", "invalid_user",
    };

    const owner_spec = owner_specs[input[0] % owner_specs.len];

    // Generate a target file path
    const file_path = try common.fuzz.generatePath(allocator, input[1..]);
    defer allocator.free(file_path);

    const args = [_][]const u8{ owner_spec, file_path };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chown_util.runChown(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // File not found, invalid user/group, permission denied, etc. are acceptable
        return;
    };
}

test "chown fuzz recursive flag" {
    try std.testing.fuzz(testing.allocator, testChownRecursive, .{});
}

fn testChownRecursive(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate owner specification
    const owner_specs = [_][]const u8{ "root", "nobody", "1000:1000" };
    const owner_spec = owner_specs[input[0] % owner_specs.len];

    // Generate a directory path
    const dir_path = try common.fuzz.generatePath(allocator, input[1..]);
    defer allocator.free(dir_path);

    const args = [_][]const u8{ "-R", owner_spec, dir_path };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chown_util.runChown(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Directory not found, permission errors, etc. are acceptable
        return;
    };
}

test "chown fuzz reference file" {
    try std.testing.fuzz(testing.allocator, testChownReferenceFile, .{});
}

fn testChownReferenceFile(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 4) return;

    // Split input for reference file and target file
    const mid = input.len / 2;
    const ref_file = try common.fuzz.generatePath(allocator, input[0..mid]);
    defer allocator.free(ref_file);

    const target_file = try common.fuzz.generatePath(allocator, input[mid..]);
    defer allocator.free(target_file);

    const args = [_][]const u8{ "--reference", ref_file, target_file };

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    _ = chown_util.runChown(allocator, &args, stdout_buf.writer(), common.null_writer) catch {
        // Reference file not found, target not found, etc. are acceptable
        return;
    };
}

test "chown fuzz symlink flags" {
    try std.testing.fuzz(testing.allocator, testChownSymlinkFlags, .{});
}

fn testChownSymlinkFlags(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    const owner_specs = [_][]const u8{ "root", "nobody", "1000:1000" };
    const owner_spec = owner_specs[input[0] % owner_specs.len];

    const file_path = try common.fuzz.generatePath(allocator, input[1..]);
    defer allocator.free(file_path);

    // Test different symlink handling flags
    const test_cases = [_][]const []const u8{
        &[_][]const u8{}, // Default behavior
        &[_][]const u8{"-h"}, // Don't follow symlinks
        &[_][]const u8{"-H"}, // Follow command line symlinks
        &[_][]const u8{"-L"}, // Follow all symlinks
        &[_][]const u8{"-P"}, // Never follow symlinks
    };

    for (test_cases) |flags| {
        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        try args.appendSlice(flags);
        try args.append(owner_spec);
        try args.append(file_path);

        _ = chown_util.runChown(allocator, args.items, common.null_writer, common.null_writer) catch {
            // All errors are acceptable in fuzzing
            continue;
        };
    }
}
