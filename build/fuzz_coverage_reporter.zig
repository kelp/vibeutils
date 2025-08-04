//! Fuzz coverage reporter utility
//!
//! This standalone utility reports fuzz test coverage for the vibeutils project.
//! It can be run independently or as part of the build system.

const std = @import("std");
const fuzz_coverage = @import("fuzz_coverage.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Print fuzz coverage report
    try fuzz_coverage.printFuzzCoverageReport(allocator);
}
