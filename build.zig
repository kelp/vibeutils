const std = @import("std");
const utils = @import("build/utils.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Coverage option - now uses Zig's native coverage
    const coverage = b.option(bool, "coverage", "Generate test coverage") orelse false;

    // Dependencies
    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    // Validate utilities exist before building
    utils.validateUtilities() catch |err| {
        std.log.err("Utility validation failed: {}", .{err});
        return; // Let build system handle the error gracefully
    };

    // Build options with version from build.zig.zon using safe parser
    const build_options = b.addOptions();
    
    const version = utils.parseVersion(b.allocator) catch |err| {
        std.log.err("Failed to parse version from build.zig.zon: {}", .{err});
        std.log.err("Ensure build.zig.zon exists and contains a valid .version field", .{});
        return; // Let build system handle the error gracefully
    };
    defer b.allocator.free(version); // Free the allocated version string
    
    build_options.addOption([]const u8, "version", version);
    
    // Create build_options module once and reuse it
    const build_options_module = build_options.createModule();
    
    // Common library module
    const common = b.addModule("common", .{
        .root_source_file = b.path("src/common/lib.zig"),
        .imports = &.{
            .{ .name = "clap", .module = clap.module("clap") },
            .{ .name = "build_options", .module = build_options_module },
        },
    });

    // Build utilities using metadata-driven approach
    for (utils.utilities) |util| {
        buildUtility(b, util, target, optimize, coverage, common, clap, build_options_module) catch |err| {
            std.log.err("Failed to build utility {s}: {}", .{util.name, err});
            return; // Let build system handle the error gracefully
        };
    }

    // Unit tests
    buildTests(b, target, optimize, coverage, common, clap, build_options_module) catch |err| {
        std.log.err("Failed to configure tests: {}", .{err});
        return; // Let build system handle the error gracefully
    };
}

/// Build a single utility with proper error handling
/// Creates executable, links necessary libraries, and sets up run steps
/// Returns error if build configuration fails
fn buildUtility(
    b: *std.Build,
    util: utils.UtilityMeta,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    coverage: bool,
    common: *std.Build.Module,
    clap: *std.Build.Dependency,
    build_options_module: *std.Build.Module,
) !void {
    const exe = b.addExecutable(.{
        .name = util.name,
        .root_source_file = b.path(util.path),
        .target = target,
        .optimize = optimize,
    });
    
    // Add imports
    exe.root_module.addImport("common", common);
    exe.root_module.addImport("clap", clap.module("clap"));
    exe.root_module.addImport("build_options", build_options_module);
    
    // Metadata-driven library linking
    if (util.needs_libc) {
        exe.linkLibC();
    }
    
    // Enable coverage if requested
    if (coverage) {
        // For now, just ensure debug info is preserved for coverage tools
        exe.root_module.strip = false;
    }
    
    b.installArtifact(exe);

    // Create run step with error handling
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    
    const run_step_name = b.fmt("run-{s}", .{util.name});
    const run_step_desc = b.fmt("Run {s} - {s}", .{util.name, util.description});
    const run_step = b.step(run_step_name, run_step_desc);
    run_step.dependOn(&run_cmd.step);
}

/// Configure tests with proper error handling
/// Uses the provided clap dependency instead of creating a new one
fn buildTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    coverage: bool,
    common: *std.Build.Module,
    clap: *std.Build.Dependency,
    build_options_module: *std.Build.Module,
) !void {
    const test_step = b.step("test", "Run unit tests");
    
    // Test each utility
    for (utils.utilities) |util| {
        const util_tests = b.addTest(.{
            .root_source_file = b.path(util.path),
            .target = target,
            .optimize = optimize,
        });
        
        util_tests.root_module.addImport("common", common);
        util_tests.root_module.addImport("clap", clap.module("clap"));
        util_tests.root_module.addImport("build_options", build_options_module);
        
        // Metadata-driven library linking for tests
        if (util.needs_libc) {
            util_tests.linkLibC();
        }
        
        // Configure coverage
        if (coverage) {
            // Preserve debug info for coverage tools
            util_tests.root_module.strip = false;
        }
        
        const run_util_tests = b.addRunArtifact(util_tests);
        test_step.dependOn(&run_util_tests.step);
    }
    
    // Common library tests
    const common_tests = b.addTest(.{
        .root_source_file = b.path("src/common/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    common_tests.root_module.addImport("build_options", build_options_module);
    
    // Configure coverage for common tests
    if (coverage) {
        // Preserve debug info for coverage tools
        common_tests.root_module.strip = false;
    }
    
    const run_common_tests = b.addRunArtifact(common_tests);
    test_step.dependOn(&run_common_tests.step);
    
    // Add benchmark executable
    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark-parsers",
        .root_source_file = b.path("src/benchmark_parsers.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    
    benchmark_exe.root_module.addImport("common", common);
    benchmark_exe.root_module.addImport("clap", clap.module("clap"));
    benchmark_exe.root_module.addImport("build_options", build_options_module);
    
    const benchmark_install = b.addInstallArtifact(benchmark_exe, .{});
    
    const benchmark_cmd = b.addRunArtifact(benchmark_exe);
    if (b.args) |args| {
        benchmark_cmd.addArgs(args);
    }
    
    const benchmark_step = b.step("benchmark", "Run parser performance benchmarks");
    benchmark_step.dependOn(&benchmark_install.step);
    benchmark_step.dependOn(&benchmark_cmd.step);
}