const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Coverage option
    const coverage = b.option(bool, "coverage", "Generate test coverage") orelse false;

    // Dependencies
    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    // Common library module
    const common = b.addModule("common", .{
        .root_source_file = b.path("src/common/lib.zig"),
        .imports = &.{
            .{ .name = "clap", .module = clap.module("clap") },
        },
    });

    // Build utilities
    const utilities = .{
        .{ "echo", "src/echo.zig" },
        .{ "cat", "src/cat.zig" },
        .{ "ls", "src/ls.zig" },
    };

    inline for (utilities) |util| {
        const exe = b.addExecutable(.{
            .name = util[0],
            .root_source_file = b.path(util[1]),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("common", common);
        exe.root_module.addImport("clap", clap.module("clap"));
        
        // Link libc for utilities that need it
        if (std.mem.eql(u8, util[0], "ls") or std.mem.eql(u8, util[0], "cat")) {
            exe.linkLibC();
        }
        
        b.installArtifact(exe);

        // Create run step
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        
        const run_step_name = b.fmt("run-{s}", .{util[0]});
        const run_step_desc = b.fmt("Run {s}", .{util[0]});
        const run_step = b.step(run_step_name, run_step_desc);
        run_step.dependOn(&run_cmd.step);
    }

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    
    // Test each utility
    inline for (utilities) |util| {
        const util_tests = b.addTest(.{
            .root_source_file = b.path(util[1]),
            .target = target,
            .optimize = optimize,
        });
        util_tests.root_module.addImport("common", common);
        util_tests.root_module.addImport("clap", clap.module("clap"));
        
        // Link libc for tests that need it
        if (std.mem.eql(u8, util[0], "ls") or std.mem.eql(u8, util[0], "cat")) {
            util_tests.linkLibC();
        }
        
        const run_util_tests = b.addRunArtifact(util_tests);
        if (coverage) {
            util_tests.setExecCmd(&[_]?[]const u8{ 
                "kcov", 
                "--exclude-pattern=/usr", 
                "zig-cache/kcov", 
                null 
            });
        }
        test_step.dependOn(&run_util_tests.step);
    }
    
    // Common library tests
    const common_tests = b.addTest(.{
        .root_source_file = b.path("src/common/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const run_common_tests = b.addRunArtifact(common_tests);
    if (coverage) {
        common_tests.setExecCmd(&[_]?[]const u8{ 
            "kcov", 
            "--exclude-pattern=/usr", 
            "zig-cache/kcov", 
            null 
        });
    }
    test_step.dependOn(&run_common_tests.step);
}