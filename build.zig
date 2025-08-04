const std = @import("std");
const utils = @import("build/utils.zig");
const fuzz_coverage = @import("build/fuzz_coverage.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Coverage option - now uses Zig's native coverage
    const coverage = b.option(bool, "coverage", "Generate test coverage") orelse false;

    // CI option - enables CI-specific behavior
    const ci = b.option(bool, "ci", "Enable CI-specific behavior") orelse false;

    // Coverage backend option
    const coverage_backend = b.option([]const u8, "coverage-backend", "Coverage backend: native, kcov") orelse "native";

    // Validate utilities exist before building
    utils.validateUtilities() catch |err| {
        std.log.err("Utility validation failed: {}", .{err});
        return; // Abort build configuration
    };

    // Validate fuzz coverage - all utilities must have fuzz tests
    fuzz_coverage.enforceFuzzCoverage(b.allocator) catch |err| {
        std.log.err("Fuzz coverage validation failed: {}", .{err});
        return; // Abort build configuration
    };

    // Build options with version from build.zig.zon using safe parser
    const build_options = b.addOptions();

    const version = utils.parseVersion(b.allocator) catch |err| {
        std.log.err("Failed to parse version from build.zig.zon: {}", .{err});
        std.log.err("Ensure build.zig.zon exists and contains a valid .version field", .{});
        return; // Abort build configuration
    };
    defer b.allocator.free(version); // Free the allocated version string

    build_options.addOption([]const u8, "version", version);

    // Create build_options module once and reuse it
    const build_options_module = build_options.createModule();

    // Common library module
    const common = b.addModule("common", .{
        .root_source_file = b.path("src/common/lib.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = build_options_module },
        },
    });

    // Build utilities using metadata-driven approach
    for (utils.utilities) |util| {
        buildUtility(b, util, target, optimize, coverage, common, build_options_module) catch |err| {
            std.log.err("Failed to build utility {s}: {}", .{ util.name, err });
            return; // Abort build configuration
        };
    }

    // Unit tests
    buildTests(b, target, optimize, coverage, common, build_options_module) catch |err| {
        std.log.err("Failed to configure tests: {}", .{err});
        return; // Abort build configuration
    };

    // Add additional build steps
    addFormatSteps(b);
    addCleanStep(b);
    addCoverageSteps(b, target, optimize, coverage_backend, common, build_options_module);
    addFuzzSteps(b, target, optimize, common, build_options_module);
    addFuzzCoverageStep(b);
    addCIValidateStep(b, ci);
    addDocsStep(b, target, optimize, common, build_options_module);
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
    const run_step_desc = b.fmt("Run {s} - {s}", .{ util.name, util.description });
    const run_step = b.step(run_step_name, run_step_desc);
    run_step.dependOn(&run_cmd.step);
}

/// Configure tests with proper error handling
fn buildTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    coverage: bool,
    common: *std.Build.Module,
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

    // Create a separate privileged test step
    const privileged_test_step = b.step("test-privileged", "Run tests that require privilege simulation (run under fakeroot)");

    // Run privileged tests only - filter for tests starting with "privileged:"
    for (utils.utilities) |util| {
        const util_tests = b.addTest(.{
            .root_source_file = b.path(util.path),
            .target = target,
            .optimize = optimize,
            .filters = &.{"privileged:"}, // Only run tests starting with "privileged:"
        });

        util_tests.root_module.addImport("common", common);
        util_tests.root_module.addImport("build_options", build_options_module);

        if (util.needs_libc) {
            util_tests.linkLibC();
        }

        const run_util_tests = b.addRunArtifact(util_tests);
        privileged_test_step.dependOn(&run_util_tests.step);
    }

    // Also add common library privileged tests if any
    const common_tests_priv = b.addTest(.{
        .root_source_file = b.path("src/common/lib.zig"),
        .target = target,
        .optimize = optimize,
        .filters = &.{"privileged:"}, // Only run tests starting with "privileged:"
    });
    common_tests_priv.root_module.addImport("build_options", build_options_module);

    const run_common_tests_priv = b.addRunArtifact(common_tests_priv);
    privileged_test_step.dependOn(&run_common_tests_priv.step);

    // Integration tests
    buildIntegrationTests(b, target, optimize, coverage, common, build_options_module) catch |err| {
        std.log.err("Failed to configure integration tests: {}", .{err});
        return; // Abort build configuration
    };
}

/// Configure integration tests for the privilege framework
fn buildIntegrationTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    coverage: bool,
    common: *std.Build.Module,
    build_options_module: *std.Build.Module,
) !void {
    const integration_test_step = b.step("test-integration", "Run privilege framework integration tests");

    // Core infrastructure integration tests
    const core_integration_tests = b.addTest(.{
        .root_source_file = b.path("src/common/privilege_test_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_integration_tests.root_module.addImport("build_options", build_options_module);

    if (coverage) {
        core_integration_tests.root_module.strip = false;
    }

    const run_core_integration = b.addRunArtifact(core_integration_tests);
    integration_test_step.dependOn(&run_core_integration.step);

    // Workflow integration tests
    const workflow_tests = b.addTest(.{
        .root_source_file = b.path("tests/privilege_integration/workflow_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    workflow_tests.root_module.addImport("common", common);

    if (coverage) {
        workflow_tests.root_module.strip = false;
    }

    const run_workflow_tests = b.addRunArtifact(workflow_tests);
    integration_test_step.dependOn(&run_workflow_tests.step);

    // File operations integration tests
    const file_ops_tests = b.addTest(.{
        .root_source_file = b.path("tests/privilege_integration/file_ops_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    file_ops_tests.root_module.addImport("common", common);

    if (coverage) {
        file_ops_tests.root_module.strip = false;
    }

    const run_file_ops_tests = b.addRunArtifact(file_ops_tests);
    integration_test_step.dependOn(&run_file_ops_tests.step);
}

/// Add format and format-check steps
fn addFormatSteps(b: *std.Build) void {
    // Format step - formats all source files
    const fmt_step = b.step("fmt", "Format all source files");
    const fmt_cmd = b.addSystemCommand(&.{ "zig", "fmt", "src/", "build.zig", "build/" });
    fmt_step.dependOn(&fmt_cmd.step);

    // Format check step - checks if files are properly formatted
    const fmt_check_step = b.step("fmt-check", "Check if source files are properly formatted");
    const fmt_check_cmd = b.addSystemCommand(&.{ "zig", "fmt", "--check", "src/", "build.zig", "build/" });
    fmt_check_step.dependOn(&fmt_check_cmd.step);
}

/// Add clean step
fn addCleanStep(b: *std.Build) void {
    const clean_step = b.step("clean", "Remove build artifacts");

    // Remove zig-cache directory
    const rm_cache = b.addRemoveDirTree(b.path("zig-cache"));
    clean_step.dependOn(&rm_cache.step);

    // Remove zig-out directory
    const rm_out = b.addRemoveDirTree(b.path("zig-out"));
    clean_step.dependOn(&rm_out.step);

    // Remove coverage directory
    const rm_coverage = b.addRemoveDirTree(b.path("coverage"));
    clean_step.dependOn(&rm_coverage.step);
}

/// Add coverage steps with multiple backend support
fn addCoverageSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    backend: []const u8,
    common: *std.Build.Module,
    build_options_module: *std.Build.Module,
) void {
    const coverage_step = b.step("coverage", "Run tests with coverage");

    if (std.mem.eql(u8, backend, "kcov")) {
        // Create coverage directory
        const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p", "coverage/kcov" });
        coverage_step.dependOn(&mkdir_cmd.step);

        // Run kcov coverage script
        const kcov_script = b.addSystemCommand(&.{"scripts/run-kcov-coverage.sh"});
        kcov_script.step.dependOn(&mkdir_cmd.step);
        coverage_step.dependOn(&kcov_script.step);
    } else {
        // Native Zig coverage
        const test_with_coverage = b.step("test-coverage", "Run tests with native coverage");

        // Run tests with coverage enabled
        for (utils.utilities) |util| {
            const util_tests = b.addTest(.{
                .root_source_file = b.path(util.path),
                .target = target,
                .optimize = optimize,
            });

            util_tests.root_module.addImport("common", common);
            util_tests.root_module.addImport("build_options", build_options_module);

            if (util.needs_libc) {
                util_tests.linkLibC();
            }

            // Enable coverage
            util_tests.root_module.strip = false;
            util_tests.setExecCmd(&.{ "zig", "build", "test", "-Dcoverage=true" });

            const run_util_tests = b.addRunArtifact(util_tests);
            test_with_coverage.dependOn(&run_util_tests.step);
        }

        coverage_step.dependOn(test_with_coverage);
    }
}

/// Add fuzz coverage reporting step
fn addFuzzCoverageStep(b: *std.Build) void {
    const fuzz_coverage_step = b.step("fuzz-coverage", "Report fuzz test coverage");

    const coverage_cmd = b.addSystemCommand(&.{ "zig", "run", "build/fuzz_coverage_reporter.zig" });

    fuzz_coverage_step.dependOn(&coverage_cmd.step);
}

/// Add CI validation step
fn addCIValidateStep(b: *std.Build, ci: bool) void {
    const ci_validate_step = b.step("ci-validate", "Validate project for CI");

    // Run CI validation script
    const validate_cmd = b.addSystemCommand(&.{"scripts/ci-validate.sh"});
    if (ci) {
        validate_cmd.setEnvironmentVariable("CI", "true");
    }
    ci_validate_step.dependOn(&validate_cmd.step);
}

/// Add documentation generation step
fn addDocsStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    common: *std.Build.Module,
    build_options_module: *std.Build.Module,
) void {
    const docs_step = b.step("docs", "Generate documentation");

    // Generate documentation for the common module
    // We need to create a dummy executable that imports the common module
    // to generate its documentation
    const common_docs_exe = b.addStaticLibrary(.{
        .name = "common-docs",
        .root_source_file = b.path("src/common/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    common_docs_exe.root_module.addImport("build_options", build_options_module);

    // Get the emitted docs for the common module
    const common_docs = common_docs_exe.getEmittedDocs();
    const install_common_docs = b.addInstallDirectory(.{
        .source_dir = common_docs,
        .install_dir = .prefix,
        .install_subdir = "docs/common",
    });
    docs_step.dependOn(&install_common_docs.step);

    // Generate documentation for each utility
    for (utils.utilities) |util| {
        const util_exe = b.addExecutable(.{
            .name = util.name,
            .root_source_file = b.path(util.path),
            .target = target,
            .optimize = optimize,
        });

        // Add imports needed for the utility
        util_exe.root_module.addImport("common", common);
        util_exe.root_module.addImport("build_options", build_options_module);

        if (util.needs_libc) {
            util_exe.linkLibC();
        }

        // Get the emitted docs for this utility
        const util_docs = util_exe.getEmittedDocs();
        const install_util_docs = b.addInstallDirectory(.{
            .source_dir = util_docs,
            .install_dir = .prefix,
            .install_subdir = b.fmt("docs/{s}", .{util.name}),
        });
        docs_step.dependOn(&install_util_docs.step);
    }

    // Add a completion message (without circular dependency)
    // This is just informational and doesn't need to be part of the step chain
}

/// Add fuzzing build steps for the project
/// Creates fuzz tests for each utility and provides commands to run them
fn addFuzzSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    common: *std.Build.Module,
    build_options_module: *std.Build.Module,
) void {
    const fuzz_step = b.step("fuzz", "Run all fuzz tests");

    // Dynamically create fuzz steps for all utilities
    for (utils.utilities) |util| {
        // Check if a dedicated fuzz file exists for this utility
        const fuzz_file_path = b.fmt("src/{s}_fuzz.zig", .{util.name});
        const fuzz_file = std.fs.cwd().openFile(fuzz_file_path, .{}) catch {
            // No fuzz file for this utility yet, skip it
            continue;
        };
        fuzz_file.close();

        // Create a build step for this utility's fuzz tests
        const fuzz_step_name = b.fmt("fuzz-{s}", .{util.name});
        const fuzz_step_desc = b.fmt("Run fuzz tests for {s} utility", .{util.name});
        const util_fuzz_step = b.step(fuzz_step_name, fuzz_step_desc);

        // Create the test executable for fuzzing
        const fuzz_test = b.addTest(.{
            .name = b.fmt("{s}-fuzz", .{util.name}),
            .root_source_file = b.path(fuzz_file_path),
            .target = target,
            .optimize = optimize,
        });

        // Add common imports
        fuzz_test.root_module.addImport("common", common);
        fuzz_test.root_module.addImport("build_options", build_options_module);

        // Add the utility module itself as an import
        // This allows the fuzz test to import the utility's functions
        const util_module = b.createModule(.{
            .root_source_file = b.path(util.path),
            .imports = &.{
                .{ .name = "common", .module = common },
                .{ .name = "build_options", .module = build_options_module },
            },
        });
        fuzz_test.root_module.addImport(util.name, util_module);

        // Link libc if needed
        if (util.needs_libc) {
            fuzz_test.linkLibC();
        }

        // Create run step for this fuzz test
        const run_fuzz = b.addRunArtifact(fuzz_test);

        // Add to both the utility-specific step and the main fuzz step
        util_fuzz_step.dependOn(&run_fuzz.step);
        fuzz_step.dependOn(&run_fuzz.step);
    }
}
