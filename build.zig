const std = @import("std");
const utils = @import("build/utils.zig");
const man = @import("build/man.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CI option - enables CI-specific behavior
    const ci = b.option(bool, "ci", "Enable CI-specific behavior") orelse false;

    // Strip option - omit debug symbols for smaller release binaries
    const strip = b.option(bool, "strip", "Omit debug symbols") orelse false;

    // Scope the unit-test step to a single utility for fast TDD iteration.
    // When null (the default) the `test` step runs every utility plus the
    // common library, exactly as before.
    const test_util = b.option([]const u8, "test-util", "Run unit tests for only this utility (by name)");

    // Validate utilities exist before building
    utils.validateUtilities(b.graph.io) catch |err| {
        std.log.err("Utility validation failed: {}", .{err});
        return; // Abort build configuration
    };

    // Build options with version from build.zig.zon using safe parser
    const build_options = b.addOptions();

    const version = utils.parseVersion(b.graph.io, b.allocator) catch |err| {
        std.log.err("Failed to parse version from build.zig.zon: {}", .{err});
        std.log.err("Ensure build.zig.zon exists and contains a valid .version field", .{});
        return; // Abort build configuration
    };
    defer b.allocator.free(version); // Free the allocated version string

    build_options.addOption([]const u8, "version", version);

    // Create build_options module once and reuse it
    const build_options_module = build_options.createModule();

    // A SECOND options module, for test roots only.
    //
    // The repo lints in src/common/lib.zig need absolute source paths, injected
    // rather than resolved from cwd: a lint that locates its inputs relative to
    // the working directory silently passes when run from anywhere else, which
    // is the vacuous-green failure issue #95 is about. Resolving at configure
    // time makes "wrong directory" impossible rather than merely unlikely.
    //
    // They go here rather than on the module above because every utility
    // imports that one, and build-machine paths are a test-only concern with no
    // business in the shipped options. (Measured: they do not actually reach a
    // ReleaseFast binary either way — Zig's lazy analysis drops the unreferenced
    // consts, and the `/home/user/...` strings visible in `strings zig-out/bin/*`
    // are DWARF DW_AT_comp_dir, which `-Dstrip` removes and which are present
    // with or without this split. This is hygiene, not a leak fix.)
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "version", version);
    test_options.addOption([]const u8, "src_dir", b.pathFromRoot("src"));
    test_options.addOption(
        []const u8,
        "common_source_dir",
        b.pathFromRoot("src/common"),
    );
    const test_options_module = test_options.createModule();

    // Common library module
    const common = b.addModule("common", .{
        .root_source_file = b.path("src/common/lib.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = build_options_module },
        },
    });

    // Build utilities using metadata-driven approach
    for (utils.utilities) |util| {
        buildUtility(b, util, target, optimize, strip, common, build_options_module) catch |err| {
            std.log.err("Failed to build utility {s}: {}", .{ util.name, err });
            return; // Abort build configuration
        };
    }

    // Unit tests. The lib.zig-rooted roots inside take test_options_module.
    buildTests(
        b,
        target,
        optimize,
        common,
        build_options_module,
        test_options_module,
        test_util,
    ) catch |err| {
        std.log.err("Failed to configure tests: {}", .{err});
        return; // Abort build configuration
    };

    // Install man pages alongside the utility binaries.
    man.addInstall(b);

    // Add additional build steps
    addFormatSteps(b);
    addCleanStep(b);
    addCIValidateStep(b, ci);
    addDocsStep(b, target, optimize, common, build_options_module);
    addCoverageStep(b, target, common, build_options_module, test_options_module);
    addFuzzer(b, target, optimize);
}

/// Build a single utility with proper error handling
/// Creates executable, links necessary libraries, and sets up run steps
/// Returns error if build configuration fails
fn buildUtility(
    b: *std.Build,
    util: utils.UtilityMeta,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    common: *std.Build.Module,
    build_options_module: *std.Build.Module,
) !void {
    const exe = b.addExecutable(.{
        .name = util.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(util.path),
            .target = target,
            .optimize = optimize,
            .strip = if (strip) true else null,
            .link_libc = if (util.needs_libc) true else null,
        }),
    });

    // Add imports
    exe.root_module.addImport("common", common);
    exe.root_module.addImport("build_options", build_options_module);

    // Add C source files if specified
    for (util.c_sources) |c_src| {
        exe.root_module.addCSourceFile(.{ .file = b.path(c_src) });
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
    common: *std.Build.Module,
    build_options_module: *std.Build.Module,
    // test_options_module carries the lint source paths; only the
    // lib.zig-rooted test binaries get it, so those paths never reach a
    // shipped utility.
    test_options_module: *std.Build.Module,
    test_util: ?[]const u8,
) !void {
    const test_step = b.step("test", "Run unit tests");

    // Track whether a `-Dtest-util=<name>` scope matched any utility so a
    // typo fails loudly instead of producing an empty (silently passing) step.
    var matched = false;

    // Test each utility
    for (utils.utilities) |util| {
        // When scoping to a single utility, still build every test artifact
        // (cheap, keeps the loop uniform) but only depend on the match.
        const want = test_util == null or std.mem.eql(u8, util.name, test_util.?);

        const util_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(util.path),
                .target = target,
                .optimize = optimize,
                .link_libc = if (util.needs_libc) true else null,
            }),
        });

        util_tests.root_module.addImport("common", common);
        util_tests.root_module.addImport("build_options", build_options_module);

        // Add C source files if specified
        for (util.c_sources) |c_src| {
            util_tests.root_module.addCSourceFile(.{ .file = b.path(c_src) });
        }

        const run_util_tests = b.addRunArtifact(util_tests);
        if (want) {
            test_step.dependOn(&run_util_tests.step);
            matched = true;
        }
    }

    // A scoped run that matched nothing is a user typo. Exit with a clean
    // one-line error and a nonzero code. Returning an error here would be
    // swallowed by build()'s `catch |err| return` convention (silent pass —
    // the failure mode a TDD gate must never have); a panic prints a noisy
    // stack trace. process.exit(1) is loud and tidy.
    if (test_util != null and !matched) {
        std.log.err("-Dtest-util: no utility named '{s}'", .{test_util.?});
        std.process.exit(1);
    }

    // Common library tests
    const common_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/common/lib.zig"),
            .target = target,
            .optimize = optimize,
            // file_ops.zig reaches std.c.fchmod/fchown/umask/geteuid directly,
            // so the common suite needs libc once its tests are force-imported.
            .link_libc = true,
        }),
    });
    common_tests.root_module.addImport("build_options", test_options_module);

    const run_common_tests = b.addRunArtifact(common_tests);
    // Skip the whole common suite when scoped to a single utility.
    if (test_util == null) {
        test_step.dependOn(&run_common_tests.step);
    }

    // Create a separate privileged test step
    const privileged_test_step = b.step("test-privileged", "Run tests that require privilege simulation (run under fakeroot)");

    // Run privileged tests only - filter for tests starting with "privileged:"
    // Chain tests sequentially to avoid FileBusy race conditions in parallel execution
    // See: https://github.com/ziglang/zig/issues/9439
    var prev_run_step: ?*std.Build.Step = null;

    for (utils.utilities) |util| {
        const util_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(util.path),
                .target = target,
                .optimize = optimize,
                .link_libc = if (util.needs_libc) true else null,
            }),
            .filters = &.{"privileged:"}, // Only run tests starting with "privileged:"
            .name = b.fmt("{s}_privileged_test", .{util.name}), // Unique name to avoid conflicts
        });

        util_tests.root_module.addImport("common", common);
        util_tests.root_module.addImport("build_options", build_options_module);

        // Add C source files if specified
        for (util.c_sources) |c_src| {
            util_tests.root_module.addCSourceFile(.{ .file = b.path(c_src) });
        }

        // WORKAROUND: The --listen=- flag breaks under fakeroot
        // See: https://github.com/ziglang/zig/issues/15091
        // Run tests directly without the server mode.
        // Install to test-bin/ (not the default bin/) so these test binaries
        // never land beside the real utilities — the integration test runner
        // scans zig-out/bin/ and would otherwise treat each as a utility.
        const install_util_tests = b.addInstallArtifact(util_tests, .{
            .dest_dir = .{ .override = .{ .custom = "test-bin" } },
        });
        const run_util_tests = b.addSystemCommand(&.{
            b.getInstallPath(install_util_tests.dest_dir.?, util_tests.out_filename),
        });
        run_util_tests.step.dependOn(&install_util_tests.step);

        // Chain each test to run after the previous one completes
        if (prev_run_step) |prev| {
            run_util_tests.step.dependOn(prev);
        }
        prev_run_step = &run_util_tests.step;

        privileged_test_step.dependOn(&run_util_tests.step);
    }

    // Also add common library privileged tests if any
    const common_tests_priv = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/common/lib.zig"),
            .target = target,
            .optimize = optimize,
            // Must match the `test` and `coverage` roots (issue #95). The
            // "privileged:" filter below leaves most tests unanalyzed, which is
            // the only reason this site survived without libc while
            // file_ops.zig reached std.c.fchmod/fchown and terminal.zig reached
            // std.c.isatty/ioctl. link_libc is also behavioral, not just a link
            // flag: env.getEnv branches on builtin.link_libc, so leaving the
            // three roots out of step made them take different env-lookup paths.
            .link_libc = true,
        }),
        .filters = &.{"privileged:"}, // Only run tests starting with "privileged:"
        .name = "common_privileged_test", // Unique name to avoid conflicts
    });
    common_tests_priv.root_module.addImport("build_options", test_options_module);

    // Same workaround as above for common library tests; same test-bin/
    // destination so it stays out of the utility bin dir.
    const install_common_tests_priv = b.addInstallArtifact(common_tests_priv, .{
        .dest_dir = .{ .override = .{ .custom = "test-bin" } },
    });
    const run_common_tests_priv = b.addSystemCommand(&.{
        b.getInstallPath(install_common_tests_priv.dest_dir.?, common_tests_priv.out_filename),
    });
    run_common_tests_priv.step.dependOn(&install_common_tests_priv.step);

    // Chain common tests to run after all utility tests
    if (prev_run_step) |prev| {
        run_common_tests_priv.step.dependOn(prev);
    }

    privileged_test_step.dependOn(&run_common_tests_priv.step);

    // Integration tests
    buildIntegrationTests(b, target, optimize, common, build_options_module) catch |err| {
        std.log.err("Failed to configure integration tests: {}", .{err});
        return; // Abort build configuration
    };
}

/// Configure integration tests for the privilege framework
fn buildIntegrationTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    common: *std.Build.Module,
    build_options_module: *std.Build.Module,
) !void {
    const integration_test_step = b.step("test-integration", "Run privilege framework integration tests");

    // Core infrastructure integration tests
    const core_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/common/privilege_test_integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    core_integration_tests.root_module.addImport("build_options", build_options_module);

    const run_core_integration = b.addRunArtifact(core_integration_tests);
    integration_test_step.dependOn(&run_core_integration.step);

    // Workflow integration tests
    const workflow_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/privilege_integration/workflow_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    workflow_tests.root_module.addImport("common", common);

    const run_workflow_tests = b.addRunArtifact(workflow_tests);
    integration_test_step.dependOn(&run_workflow_tests.step);

    // File operations integration tests
    const file_ops_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/privilege_integration/file_ops_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    file_ops_tests.root_module.addImport("common", common);

    const run_file_ops_tests = b.addRunArtifact(file_ops_tests);
    integration_test_step.dependOn(&run_file_ops_tests.step);
}

/// Add format and format-check steps
fn addFormatSteps(b: *std.Build) void {
    // Format step - formats all source files
    const fmt_step = b.step("fmt", "Format all source files");
    const fmt_cmd = b.addSystemCommand(&.{ "zig", "fmt", "src/", "build.zig", "build/", "tools/" });
    fmt_step.dependOn(&fmt_cmd.step);

    // Format check step - checks if files are properly formatted
    const fmt_check_step = b.step("fmt-check", "Check if source files are properly formatted");
    const fmt_check_cmd = b.addSystemCommand(&.{ "zig", "fmt", "--check", "src/", "build.zig", "build/", "tools/" });
    fmt_check_step.dependOn(&fmt_check_cmd.step);
}

/// Add clean step
fn addCleanStep(b: *std.Build) void {
    const clean_step = b.step("clean", "Remove build artifacts");

    // 0.16 removed addRemoveDirTree; shell out instead.
    const rm = b.addSystemCommand(&.{ "rm", "-rf", ".zig-cache", "zig-cache", "zig-out" });
    clean_step.dependOn(&rm.step);
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
    const common_docs_exe = b.addLibrary(.{
        .name = "common-docs",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/common/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
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
            .root_module = b.createModule(.{
                .root_source_file = b.path(util.path),
                .target = target,
                .optimize = optimize,
                .link_libc = if (util.needs_libc) true else null,
            }),
        });

        // Add imports needed for the utility
        util_exe.root_module.addImport("common", common);
        util_exe.root_module.addImport("build_options", build_options_module);

        // Add C source files if specified
        for (util.c_sources) |c_src| {
            util_exe.root_module.addCSourceFile(.{ .file = b.path(c_src) });
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

/// Add coverage step - builds test binaries with LLVM backend for kcov
/// Binaries are installed to zig-out/bin/tests/ but NOT run.
/// Use scripts/coverage.sh to run them under kcov.
fn addCoverageStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    common: *std.Build.Module,
    build_options_module: *std.Build.Module,
    test_options_module: *std.Build.Module,
) void {
    const coverage_step = b.step("coverage", "Build test binaries with LLVM backend for coverage analysis");

    // Build test binary for each utility
    for (utils.utilities) |util| {
        const util_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(util.path),
                .target = target,
                .optimize = .Debug,
                .link_libc = if (util.needs_libc) true else null,
            }),
            .use_llvm = true,
            .name = b.fmt("{s}_test", .{util.name}),
        });

        util_tests.root_module.addImport("common", common);
        util_tests.root_module.addImport("build_options", build_options_module);

        for (util.c_sources) |c_src| {
            util_tests.root_module.addCSourceFile(.{ .file = b.path(c_src) });
        }

        // Install binary to zig-out/bin/tests/ without running
        const install = b.addInstallArtifact(util_tests, .{
            .dest_dir = .{ .override = .{ .custom = "bin/tests" } },
        });
        coverage_step.dependOn(&install.step);
    }

    // Build test binary for common library
    const common_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/common/lib.zig"),
            .target = target,
            .optimize = .Debug,
            // Unfiltered, so every force-imported module is analyzed, including
            // file_ops.zig's reach into std.c.fchmod/fchown/umask/geteuid. The
            // test-privileged binary escapes this only because its
            // "privileged:" filter leaves those tests unanalyzed.
            .link_libc = true,
        }),
        .use_llvm = true,
        .name = "common_test",
    });
    common_tests.root_module.addImport("build_options", test_options_module);

    const install_common = b.addInstallArtifact(common_tests, .{
        .dest_dir = .{ .override = .{ .custom = "bin/tests" } },
    });
    coverage_step.dependOn(&install_common.step);
}

/// Build the homegrown fuzzer and wire one `fuzz-<util>` step per utility.
/// The fuzzer is std-only and intentionally does not import `common`.
fn addFuzzer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Intentionally not installed: the fuzzer is a dev tool, not a user
    // utility. Installing it would land it in zig-out/bin/ where the
    // integration test runner would mistake it for a coreutil to test.
    // b.addRunArtifact below builds it from cache without installing.

    for (utils.utilities) |util| {
        const run_cmd = b.addRunArtifact(fuzz_exe);
        run_cmd.step.dependOn(b.getInstallStep());

        const bin_path = b.getInstallPath(.prefix, b.fmt("bin/{s}", .{util.name}));
        run_cmd.addArg(bin_path);
        run_cmd.addArg("--util");
        run_cmd.addArg(util.name);
        run_cmd.addArg("--corpus");
        run_cmd.addArg(b.fmt("tests/fuzz/{s}/corpus", .{util.name}));
        run_cmd.addArg("--crashes");
        run_cmd.addArg(b.fmt("tests/fuzz/{s}/crashes", .{util.name}));

        if (b.args) |a| run_cmd.addArgs(a);

        const fuzz_step = b.step(
            b.fmt("fuzz-{s}", .{util.name}),
            b.fmt("Fuzz {s}", .{util.name}),
        );
        fuzz_step.dependOn(&run_cmd.step);
    }
}
